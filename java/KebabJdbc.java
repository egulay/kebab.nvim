// JDBC bridge for kebab.nvim's SQL support.
//
// Run in Java's single-file source mode, so there is no build step and nothing
// to ship but this file:
//
//   java -cp '<driver jars>' KebabJdbc.java <mode> <jdbc-url> [args...]
//
// SQL arrives on stdin. Modes:
//
//   query    run the SQL and print an aligned result table
//   tables   one "schema.table" per line, from DatabaseMetaData
//   columns  one "name<TAB>type<TAB>nullable" per line for the given table
//   schema   "table<TAB>column<TAB>type" for the whole database, for completion
//   ping     exit 0 if the connection opens
//   serve    stay alive and answer many requests on one open connection
//
// `serve` is why this is fast. Measured on a warm cache: the first
// connection-and-query in a JVM costs 140ms, the second 0.5ms, and twenty
// queries on one open connection 1.0ms in total. Nearly all of the cost is
// one-time per *process* -- driver class loading, and for SQLite extracting a
// bundled native library -- so holding the process open turns 180ms per query
// into 0.3ms.
//
// The serve protocol is length-prefixed rather than line- or sentinel-
// delimited, because SQL contains newlines and any sentinel could in principle
// appear inside a query:
//
//   request   <mode>\t<arg>\t<payload-byte-length>\n<payload bytes>
//   response  <OK|ERR>\t<payload-byte-length>\n<payload bytes>
//
// Why JDBC rather than the native clients vim-dadbod shells out to: the driver
// is a jar from Maven, so a database needs no psql/mysql binary installed, and
// DatabaseMetaData gives real schema introspection instead of parsing SQL.
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.Driver;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Enumeration;
import java.util.HashSet;
import java.util.List;
import java.util.Properties;
import java.util.Set;

public final class KebabJdbc {

  public static void main(String[] args) {
    if (args.length < 2) {
      System.err.println("usage: KebabJdbc <mode> <jdbc-url> [args...]");
      System.exit(2);
    }
    String mode = args[0];
    // "-" means "read the URL from KEBAB_DB_URL". argv is world-readable in
    // the process list, so a URL carrying inline credentials -- which some
    // drivers accept, e.g. jdbc:...?user=x&password=y -- must not be passed
    // that way. The env is per process and not listed.
    String url = args[1];
    if ("-".equals(url)) {
      url = System.getenv("KEBAB_DB_URL");
      if (url == null || url.isBlank()) {
        System.err.println("KEBAB_DB_URL is not set, and the url argument was \"-\"");
        System.exit(2);
      }
    }

    Properties props = new Properties();
    // Credentials come through the environment, never the command line, so they
    // do not show up in the process list.
    String user = System.getenv("KEBAB_DB_USER");
    String pass = System.getenv("KEBAB_DB_PASSWORD");
    if (user != null && !user.isEmpty()) props.setProperty("user", user);
    if (pass != null && !pass.isEmpty()) props.setProperty("password", pass);

    try (Connection conn = DriverManager.getConnection(url, props)) {
      switch (mode) {
        case "ping" -> ping(conn);
        case "tables" -> tables(conn);
        case "columns" -> columns(conn, args.length > 2 ? args[2] : null);
        case "structure" -> structure(conn, args.length > 2 ? args[2] : null);
        case "schema" -> schema(conn);
        case "query" -> query(conn, readStdin());
        case "page" -> page(conn, args.length > 2 ? args[2] : null, readStdin());
        case "serve" -> serve(conn);
        default -> {
          System.err.println("unknown mode: " + mode);
          System.exit(2);
        }
      }
    } catch (UsageException e) {
      // A bad argument, not a database failure: still exit 2 as it always has,
      // but by throwing out of the printer rather than calling System.exit
      // inside it -- in serve mode that killed the JVM mid-protocol, left the
      // request unanswered, skipped the try-with-resources that closes the
      // shared connection, and failed every other request queued on it.
      System.err.println(e.getMessage());
      System.exit(2);
    } catch (SQLException e) {
      System.err.println(describe(e));
      System.exit(1);
    } catch (Exception e) {
      System.err.println(e.getClass().getSimpleName() + ": " + e.getMessage());
      System.exit(1);
    }
  }

  // ------------------------------------------------------------------ serve

  /**
   * Answer requests on stdin until the stream closes or a "close" arrives,
   * reusing one open connection throughout.
   */
  private static void serve(Connection conn) throws Exception {
    java.io.InputStream in = System.in;
    java.io.OutputStream out = System.out;
    while (true) {
      String header = readLine(in);
      if (header == null) {
        return; // the client went away
      }
      if (header.isEmpty()) {
        continue;
      }
      // A malformed header cannot be recovered from by replying and carrying
      // on: the payload bytes it declared are still in the stream, and the
      // next read would take them as a header. Everything after that is
      // garbage, so stop rather than answer nonsense with confidence.
      String[] parts = header.split("\t", -1);
      if (parts.length < 3) {
        respond(out, false, "malformed request header; closing the connection");
        return;
      }
      String mode = parts[0];
      String arg = parts[1];
      int length;
      try {
        length = Integer.parseInt(parts[2].trim());
      } catch (NumberFormatException e) {
        respond(out, false, "malformed payload length; closing the connection");
        return;
      }
      if (length < 0) {
        respond(out, false, "negative payload length; closing the connection");
        return;
      }
      String payload = readExactly(in, length);
      if (payload == null) {
        return;
      }
      if (mode.equals("close")) {
        Cursor.close();
        respond(out, true, "");
        return;
      }
      try {
        respond(out, true, capture(conn, mode, arg, payload));
      } catch (SQLException e) {
        respond(out, false, describe(e));
      } catch (Exception e) {
        respond(out, false, e.getClass().getSimpleName() + ": " + e.getMessage());
      }
    }
  }

  /** Run a mode with stdout redirected, so the existing printers are reused verbatim. */
  private static String capture(Connection conn, String mode, String arg, String payload)
      throws Exception {
    java.io.PrintStream original = System.out;
    ByteArrayOutputStream buffer = new ByteArrayOutputStream();
    System.setOut(new java.io.PrintStream(buffer, true, StandardCharsets.UTF_8));
    try {
      switch (mode) {
        case "ping" -> ping(conn);
        case "tables" -> tables(conn);
        case "columns" -> columns(conn, arg);
        case "structure" -> structure(conn, arg);
        case "schema" -> schema(conn);
        case "query" -> {
          Cursor.close(); // a new statement replaces the open result set
          query(conn, payload);
        }
        case "page" -> {
          Cursor.close();
          page(conn, arg, payload);
        }
        case "cursor" -> Cursor.handle(conn, arg, payload);
        default -> throw new IllegalArgumentException("unknown mode: " + mode);
      }
    } finally {
      System.setOut(original);
    }
    return buffer.toString(StandardCharsets.UTF_8);
  }

  private static void respond(java.io.OutputStream out, boolean ok, String body) throws Exception {
    byte[] bytes = body == null ? new byte[0] : body.getBytes(StandardCharsets.UTF_8);
    out.write(((ok ? "OK" : "ERR") + "\t" + bytes.length + "\n").getBytes(StandardCharsets.UTF_8));
    out.write(bytes);
    out.flush();
  }

  /** Read up to a newline. Returns null at end of stream. */
  private static String readLine(java.io.InputStream in) throws Exception {
    ByteArrayOutputStream buffer = new ByteArrayOutputStream();
    int c;
    while ((c = in.read()) != -1) {
      if (c == '\n') {
        return buffer.toString(StandardCharsets.UTF_8);
      }
      buffer.write(c);
    }
    return buffer.size() == 0 ? null : buffer.toString(StandardCharsets.UTF_8);
  }

  /** Read exactly n bytes. Returns null if the stream ends first. */
  private static String readExactly(java.io.InputStream in, int n) throws Exception {
    if (n <= 0) {
      return "";
    }
    byte[] buf = new byte[n];
    int read = 0;
    while (read < n) {
      int got = in.read(buf, read, n - read);
      if (got < 0) {
        return null;
      }
      read += got;
    }
    return new String(buf, StandardCharsets.UTF_8);
  }

  /** A driver that is simply not on the classpath is the most likely failure, so name it. */
  private static String describe(SQLException e) {
    String msg = e.getMessage() == null ? e.toString() : e.getMessage();
    if (msg.contains("No suitable driver")) {
      List<String> loaded = new ArrayList<>();
      Enumeration<Driver> drivers = DriverManager.getDrivers();
      while (drivers.hasMoreElements()) {
        loaded.add(drivers.nextElement().getClass().getName());
      }
      return "No suitable driver for this URL. Drivers on the classpath: "
          + (loaded.isEmpty() ? "(none)" : String.join(", ", loaded));
    }
    return msg;
  }

  private static void ping(Connection conn) throws SQLException {
    DatabaseMetaData md = conn.getMetaData();
    System.out.println(md.getDatabaseProductName() + " " + md.getDatabaseProductVersion());
  }

  private static void tables(Connection conn) throws SQLException {
    DatabaseMetaData md = conn.getMetaData();
    boolean all = "1".equals(System.getenv("KEBAB_DB_ALL_SCHEMAS"));
    Set<String> system = systemSchemas(md);
    try (ResultSet rs = md.getTables(null, null, "%", new String[] {"TABLE", "VIEW"})) {
      while (rs.next()) {
        String schema = rs.getString("TABLE_SCHEM");
        String name = rs.getString("TABLE_NAME");
        if (!all && isSystemSchema(system, schema)) continue;
        System.out.println(qualify(schema, name));
      }
    }
  }

  /**
   * The schemas a database keeps its own catalog in.
   *
   * <p>Why this is here: `getTables(null, null, "%")` means every schema the
   * user can see, and on two of the drivers this layer supports that is almost
   * entirely the server's own. Measured against real servers: 616 tables on a
   * fresh SQL Server, of which 589 are `sys` and 21 `INFORMATION_SCHEMA` -- six
   * were the user's. 2051 on a fresh Oracle, of which two were the user's. The
   * data source tree lists what this returns, so an Oracle connection was
   * unusable: the tables you are looking for are somewhere inside two thousand
   * entries named after the data dictionary. PostgreSQL's driver already
   * excludes its own, which is why nobody noticed.
   *
   * <p>`KEBAB_DB_ALL_SCHEMAS=1` turns the filter off, for the rare case of
   * actually wanting to read the catalog -- and for a user whose own schema
   * collides with a name below.
   */
  private static Set<String> systemSchemas(DatabaseMetaData md) {
    String product;
    try {
      product = md.getDatabaseProductName() == null ? "" : md.getDatabaseProductName().toLowerCase();
    } catch (SQLException e) {
      product = "";
    }
    Set<String> out = new HashSet<>();
    if (product.contains("oracle")) {
      out.addAll(
          Arrays.asList(
              "sys", "system", "xdb", "mdsys", "ctxsys", "dbsnmp", "outln", "audsys", "orddata",
              "ordsys", "lbacsys", "olapsys", "appqossys", "dvsys", "gsmadmin_internal", "wmsys",
              "si_informtn_schema", "dbsfwuser", "ggsys", "remote_scheduler_agent", "anonymous",
              "dip", "oracle_ocm", "sysbackup", "sysdg", "syskm", "sysrac", "sys$umf", "pdbadmin",
              "oml$metadata", "rdsadmin"));
    } else if (product.contains("microsoft sql server")) {
      out.addAll(Arrays.asList("sys", "information_schema"));
    } else if (product.contains("mysql") || product.contains("mariadb")) {
      out.addAll(Arrays.asList("information_schema", "mysql", "performance_schema", "sys"));
    } else if (product.contains("postgresql")) {
      out.addAll(Arrays.asList("pg_catalog", "information_schema", "pg_toast"));
    } else if (product.contains("clickhouse")) {
      out.addAll(Arrays.asList("system", "information_schema"));
    } else if (product.contains("h2")) {
      out.add("information_schema");
    } else if (product.contains("duckdb")) {
      out.addAll(Arrays.asList("information_schema", "pg_catalog"));
    }
    return out;
  }

  /** Oracle's packaged applications bring whole families of schemas. */
  private static final String[] SYSTEM_SCHEMA_PREFIXES = {"apex_", "flows_", "ords_"};

  private static boolean isSystemSchema(Set<String> system, String schema) {
    if (schema == null || schema.isEmpty()) return false;
    String lower = schema.toLowerCase();
    if (system.contains(lower)) return true;
    for (String prefix : SYSTEM_SCHEMA_PREFIXES) {
      if (lower.startsWith(prefix)) return true;
    }
    return false;
  }

  /**
   * The schema and table as the catalog spells them.
   *
   * <p>DatabaseMetaData matches identifiers *exactly*, and a database that
   * folds unquoted names to one case stores them in that case: on Oracle
   * `kebab_items` is `KEBAB_ITEMS`, so asking for the columns of the name the
   * user typed returned nothing at all -- an empty structure panel with no
   * error, which is the worst of the available outcomes. The name that comes
   * from the data source tree is already the stored one, so clicking worked
   * and typing did not.
   *
   * <p>Resolved by asking the catalog: the name as given, then the case the
   * driver says it stores, then a case-insensitive scan. Falls back to what
   * was asked for, so the caller still gets its empty result and not an error.
   */
  private static String[] resolveTable(DatabaseMetaData md, String schema, String name)
      throws SQLException {
    String[] asked = new String[] {schema, name};
    if (name == null || name.isEmpty()) return asked;
    if (tableExists(md, schema, name)) return asked;

    List<String[]> candidates = new ArrayList<>();
    if (md.storesUpperCaseIdentifiers()) {
      candidates.add(new String[] {schema == null ? null : schema.toUpperCase(), name.toUpperCase()});
    }
    if (md.storesLowerCaseIdentifiers()) {
      candidates.add(new String[] {schema == null ? null : schema.toLowerCase(), name.toLowerCase()});
    }
    for (String[] candidate : candidates) {
      if (tableExists(md, candidate[0], candidate[1])) return candidate;
    }

    // Last resort: the driver may fold differently again, or the name may be
    // genuinely mixed case in a quoted-identifier database.
    try (ResultSet rs = md.getTables(null, null, "%", new String[] {"TABLE", "VIEW"})) {
      while (rs.next()) {
        String foundSchema = rs.getString("TABLE_SCHEM");
        String foundName = rs.getString("TABLE_NAME");
        if (foundName == null || !foundName.equalsIgnoreCase(name)) continue;
        if (schema != null && !schema.isEmpty()
            && (foundSchema == null || !foundSchema.equalsIgnoreCase(schema))) {
          continue;
        }
        return new String[] {foundSchema, foundName};
      }
    }
    return asked;
  }

  private static boolean tableExists(DatabaseMetaData md, String schema, String name)
      throws SQLException {
    try (ResultSet rs =
        md.getTables(null, likeLiteral(md, schema), likeLiteral(md, name),
            new String[] {"TABLE", "VIEW"})) {
      return rs.next();
    }
  }

  private static void columns(Connection conn, String table) throws SQLException {
    if (table == null || table.isEmpty()) {
      throw new UsageException("columns needs a table name");
    }
    String schema = null;
    String name = table;
    int dot = table.lastIndexOf('.');
    if (dot > 0) {
      schema = table.substring(0, dot);
      name = table.substring(dot + 1);
    }
    DatabaseMetaData md = conn.getMetaData();
    String[] resolved = resolveTable(md, schema, name);
    schema = resolved[0];
    name = resolved[1];
    try (ResultSet rs = md.getColumns(null, likeLiteral(md, schema), likeLiteral(md, name), "%")) {
      while (rs.next()) {
        System.out.println(
            rs.getString("COLUMN_NAME")
                + "\t"
                + rs.getString("TYPE_NAME")
                + "\t"
                + ("YES".equals(rs.getString("IS_NULLABLE")) ? "null" : "not null"));
      }
    }
  }

  /** Everything completion needs, in one round trip. */
  /**
   * How a table is built: its columns, its key, what it points at, what points
   * at it, and its indexes.
   *
   * <p>This is the half of a database IDE that is not the data. Reading
   * somebody else's schema -- which is what you are doing when you sit down
   * with their database -- means asking what the columns are, which of them is
   * the key, and how the tables are joined. All of it comes from
   * DatabaseMetaData, so it works on every driver rather than on the two whose
   * dialect someone remembered.
   *
   * <p>Printed in labelled sections so the caller can split them without
   * parsing SQL. Sections with nothing in them are still printed, because "no
   * foreign keys" is an answer.
   */
  private static void structure(Connection conn, String table) throws SQLException {
    if (table == null || table.isEmpty()) {
      throw new UsageException("structure needs a table name");
    }
    String schema = null;
    String name = table;
    int dot = table.lastIndexOf('.');
    if (dot > 0) {
      schema = table.substring(0, dot);
      name = table.substring(dot + 1);
    }
    DatabaseMetaData md = conn.getMetaData();
    String[] resolved = resolveTable(md, schema, name);
    schema = resolved[0];
    name = resolved[1];
    String schemaPattern = likeLiteral(md, schema);
    String namePattern = likeLiteral(md, name);

    // which columns are in the primary key, and in what order
    List<String> key = new ArrayList<>();
    try (ResultSet rs = md.getPrimaryKeys(null, schema, name)) {
      java.util.TreeMap<Short, String> ordered = new java.util.TreeMap<>();
      while (rs.next()) {
        ordered.put(rs.getShort("KEY_SEQ"), rs.getString("COLUMN_NAME"));
      }
      key.addAll(ordered.values());
    }

    System.out.println("-- columns");
    try (ResultSet rs = md.getColumns(null, schemaPattern, namePattern, "%")) {
      while (rs.next()) {
        String column = rs.getString("COLUMN_NAME");
        String type = rs.getString("TYPE_NAME");
        int size = rs.getInt("COLUMN_SIZE");
        int digits = rs.getInt("DECIMAL_DIGITS");
        boolean hasDigits = !rs.wasNull();
        // A type is useless without its size for char and decimal columns:
        // varchar(20) and varchar(2000) are not the same design decision.
        String sized = type;
        if (size > 0 && type != null) {
          String lower = type.toLowerCase(java.util.Locale.ROOT);
          if (lower.contains("char") || lower.contains("binary")) {
            sized = type + "(" + size + ")";
          } else if (hasDigits && digits > 0 && (lower.contains("dec") || lower.contains("numeric"))) {
            sized = type + "(" + size + "," + digits + ")";
          }
        }
        String fallback = rs.getString("COLUMN_DEF");
        String auto = "YES".equals(safe(rs, "IS_AUTOINCREMENT")) ? "auto" : "";
        System.out.println(
            column
                + "\t"
                + sized
                + "\t"
                + ("YES".equals(rs.getString("IS_NULLABLE")) ? "null" : "not null")
                + "\t"
                + (fallback == null ? "" : fallback.trim())
                + "\t"
                + (key.contains(column) ? "pk" : "")
                + "\t"
                + auto);
      }
    }

    System.out.println("-- primary key");
    if (!key.isEmpty()) {
      System.out.println(String.join(", ", key));
    }

    System.out.println("-- foreign keys");
    try (ResultSet rs = md.getImportedKeys(null, schema, name)) {
      while (rs.next()) {
        System.out.println(
            rs.getString("FKCOLUMN_NAME")
                + "\t"
                + qualify(rs.getString("PKTABLE_SCHEM"), rs.getString("PKTABLE_NAME"))
                + "\t"
                + rs.getString("PKCOLUMN_NAME")
                + "\t"
                + safe(rs, "FK_NAME"));
      }
    }

    System.out.println("-- referenced by");
    try (ResultSet rs = md.getExportedKeys(null, schema, name)) {
      while (rs.next()) {
        System.out.println(
            qualify(rs.getString("FKTABLE_SCHEM"), rs.getString("FKTABLE_NAME"))
                + "\t"
                + rs.getString("FKCOLUMN_NAME")
                + "\t"
                + rs.getString("PKCOLUMN_NAME")
                + "\t"
                + safe(rs, "FK_NAME"));
      }
    }

    System.out.println("-- indexes");
    try (ResultSet rs = md.getIndexInfo(null, schema, name, false, true)) {
      // One row per column, so they are gathered per index and in position
      // order -- an index on (a, b) is not the same index as one on (b, a).
      java.util.LinkedHashMap<String, java.util.TreeMap<Short, String>> byName =
          new java.util.LinkedHashMap<>();
      java.util.LinkedHashMap<String, Boolean> unique = new java.util.LinkedHashMap<>();
      while (rs.next()) {
        String index = rs.getString("INDEX_NAME");
        if (index == null) {
          continue; // tableIndexStatistic rows carry no name
        }
        byName.computeIfAbsent(index, k -> new java.util.TreeMap<>())
            .put(rs.getShort("ORDINAL_POSITION"), rs.getString("COLUMN_NAME"));
        unique.putIfAbsent(index, !rs.getBoolean("NON_UNIQUE"));
      }
      for (java.util.Map.Entry<String, java.util.TreeMap<Short, String>> entry : byName.entrySet()) {
        System.out.println(
            entry.getKey()
                + "\t"
                + (Boolean.TRUE.equals(unique.get(entry.getKey())) ? "unique" : "")
                + "\t"
                + String.join(", ", entry.getValue().values()));
      }
    }
  }

  /** A metadata column a driver may not have: absent is not a failure. */
  private static String safe(ResultSet rs, String column) {
    try {
      String value = rs.getString(column);
      return value == null ? "" : value;
    } catch (SQLException e) {
      return "";
    }
  }

  private static void schema(Connection conn) throws SQLException {
    DatabaseMetaData md = conn.getMetaData();
    boolean all = "1".equals(System.getenv("KEBAB_DB_ALL_SCHEMAS"));
    Set<String> system = systemSchemas(md);
    List<String> names = new ArrayList<>();
    try (ResultSet rs = md.getTables(null, null, "%", new String[] {"TABLE", "VIEW"})) {
      while (rs.next()) {
        String schema = rs.getString("TABLE_SCHEM");
        if (!all && isSystemSchema(system, schema)) continue;
        names.add(qualify(schema, rs.getString("TABLE_NAME")));
      }
    }
    for (String full : names) {
      String schema = null;
      String name = full;
      int dot = full.lastIndexOf('.');
      if (dot > 0) {
        schema = full.substring(0, dot);
        name = full.substring(dot + 1);
      }
      try (ResultSet rs = md.getColumns(null, likeLiteral(md, schema), likeLiteral(md, name), "%")) {
        while (rs.next()) {
          System.out.println(full + "\t" + rs.getString("COLUMN_NAME") + "\t" + rs.getString("TYPE_NAME"));
        }
      }
    }
  }

  private static String qualify(String schema, String name) {
    // Most databases report a schema; SQLite does not, and "null.customers"
    // would be a nonsense table name.
    if (schema == null || schema.isEmpty() || "null".equals(schema)) return name;
    return schema + "." + name;
  }

  /**
   * Escape a name for the LIKE-pattern arguments DatabaseMetaData takes.
   *
   * <p>getColumns treats its schema and table arguments as patterns, so an
   * identifier holding `_` matched any character: asking for the columns of
   * `user_data` also returned those of `userXdata`, and the completion schema
   * attributed them to the wrong table.
   */
  private static String likeLiteral(DatabaseMetaData md, String name) throws SQLException {
    if (name == null) return null;
    String esc = md.getSearchStringEscape();
    if (esc == null || esc.isEmpty()) return name;
    StringBuilder sb = new StringBuilder(name.length());
    for (int i = 0; i < name.length(); i++) {
      char c = name.charAt(i);
      if (c == '_' || c == '%' || esc.indexOf(c) >= 0) sb.append(esc);
      sb.append(c);
    }
    return sb.toString();
  }

  /** A bad request. Fails one request; in serve mode the JVM must survive it. */
  static class UsageException extends RuntimeException {
    UsageException(String message) {
      super(message);
    }
  }

  /**
   * Split a script into statements on unquoted, uncommented semicolons.
   *
   * <p>This exists because a driver may compile only the first statement of a
   * multi-statement payload -- SQLite's does -- and then everything after the
   * first `;` silently never runs while the bridge still reports success. A
   * half-applied migration is the worst outcome available, so the splitting is
   * done here rather than hoped for from the driver.
   */
  static List<String> splitStatements(String sql) {
    List<String> out = new ArrayList<>();
    StringBuilder current = new StringBuilder();
    int i = 0;
    int n = sql.length();
    while (i < n) {
      char c = sql.charAt(i);
      // line comment
      if (c == '-' && i + 1 < n && sql.charAt(i + 1) == '-') {
        int end = sql.indexOf('\n', i);
        if (end < 0) end = n;
        current.append(sql, i, end);
        i = end;
        continue;
      }
      // block comment (not nested, which is standard SQL)
      if (c == '/' && i + 1 < n && sql.charAt(i + 1) == '*') {
        int end = sql.indexOf("*/", i + 2);
        end = end < 0 ? n : end + 2;
        current.append(sql, i, end);
        i = end;
        continue;
      }
      // quoted string or identifier; the quote doubles to escape itself
      if (c == '\'' || c == '"' || c == '`') {
        int j = i + 1;
        while (j < n) {
          if (sql.charAt(j) == c) {
            if (j + 1 < n && sql.charAt(j + 1) == c) {
              j += 2;
              continue;
            }
            j++;
            break;
          }
          j++;
        }
        current.append(sql, i, Math.min(j, n));
        i = j;
        continue;
      }
      // PostgreSQL dollar quoting: $tag$ ... $tag$
      if (c == '$') {
        int close = sql.indexOf('$', i + 1);
        if (close > i) {
          String tag = sql.substring(i, close + 1);
          int end = sql.indexOf(tag, close + 1);
          if (end > 0) {
            end += tag.length();
            current.append(sql, i, end);
            i = end;
            continue;
          }
        }
      }
      if (c == ';') {
        out.add(current.toString());
        current.setLength(0);
        i++;
        continue;
      }
      current.append(c);
      i++;
    }
    out.add(current.toString());

    List<String> kept = new ArrayList<>();
    for (String one : out) {
      // A fragment holding only comments and whitespace is not a statement;
      // handing one to the driver raised "the prepared statement has been
      // finalized" on a script that merely ended with a comment.
      if (!isOnlyComments(one)) kept.add(one.trim());
    }
    return kept;
  }

  /** True when `sql` holds nothing but whitespace and comments. */
  static boolean isOnlyComments(String sql) {
    int i = 0;
    int n = sql.length();
    while (i < n) {
      char c = sql.charAt(i);
      if (Character.isWhitespace(c)) {
        i++;
      } else if (c == '-' && i + 1 < n && sql.charAt(i + 1) == '-') {
        int end = sql.indexOf('\n', i);
        i = end < 0 ? n : end + 1;
      } else if (c == '/' && i + 1 < n && sql.charAt(i + 1) == '*') {
        int end = sql.indexOf("*/", i + 2);
        i = end < 0 ? n : end + 2;
      } else {
        return false;
      }
    }
    return true;
  }

  private static void query(Connection conn, String sql) throws SQLException {
    if (sql.isBlank()) {
      throw new UsageException("nothing to run");
    }
    List<String> statements = splitStatements(sql);
    if (statements.isEmpty()) {
      throw new UsageException("nothing to run");
    }
    for (int index = 0; index < statements.size(); index++) {
      String one = statements.get(index);
      try {
        runOne(conn, one);
      } catch (SQLException e) {
        // Say which one, because the earlier ones did run and a caller has to
        // know how far the script got. It goes in the *message*, not on
        // stdout: serve mode discards buffered output when a request fails.
        if (statements.size() > 1) {
          throw new SQLException(
              "statement "
                  + (index + 1)
                  + " of "
                  + statements.size()
                  + " failed ("
                  + (index)
                  + " applied): "
                  + e.getMessage(),
              e.getSQLState(),
              e.getErrorCode(),
              e);
        }
        throw e;
      }
    }
  }

  /**
   * One page of a single statement's rows.
   *
   * <p>Paging belongs here rather than in the SQL because every dialect spells
   * it differently and some statements cannot be wrapped or extended at all: a
   * select that already carries its own LIMIT, a CTE, {@code select ... for
   * update}. Skipping rows on the cursor works for any statement and needs no
   * dialect table.
   *
   * <p>The cost is that page n reads n*size rows from the cursor. For
   * interactive paging that is the right trade: the driver is streaming, the
   * warm process keeps the connection, and a page flip is a round trip either
   * way. It is not the right trade for walking a ten million row table to the
   * end, which is what a WHERE clause is for.
   *
   * @param arg "<offset>:<size>"
   */
  private static void page(Connection conn, String arg, String sql) throws SQLException {
    long offset = 0;
    int size = 100;
    if (arg != null && !arg.isBlank()) {
      String[] parts = arg.split(":", 2);
      try {
        offset = Long.parseLong(parts[0].trim());
        if (parts.length > 1) size = Integer.parseInt(parts[1].trim());
      } catch (NumberFormatException e) {
        throw new UsageException("page takes <offset>:<size>, got: " + arg);
      }
    }
    if (offset < 0 || size < 1) {
      throw new UsageException("page needs offset >= 0 and size >= 1, got: " + arg);
    }
    if (sql.isBlank()) {
      throw new UsageException("nothing to run");
    }
    List<String> statements = splitStatements(sql);
    if (statements.isEmpty()) {
      throw new UsageException("nothing to run");
    }
    if (statements.size() > 1) {
      // Paging a script has no meaning: which statement's rows would it be?
      throw new UsageException("paging needs a single statement, got " + statements.size());
    }

    // PostgreSQL's driver only streams -- i.e. honours the fetch size -- inside
    // a transaction; outside one it materialises the whole result set, so
    // `select * from a_big_table` would be read into memory in full before the
    // first page could be shown. Every driver here is happy to have autocommit
    // turned off for a read, and it is restored below.
    boolean autocommit = conn.getAutoCommit();
    boolean streamed = false;
    try {
      if (autocommit) {
        try {
          conn.setAutoCommit(false);
          streamed = true;
        } catch (SQLException e) {
          // a driver that refuses is no worse off than before
          streamed = false;
        }
      }
      try (Statement st = conn.createStatement()) {
        try {
          st.setFetchSize(Math.min(size + 1, 1000));
        } catch (SQLException e) {
          // advisory on every driver that has it; ignorable where it does not
        }
        boolean hasResult = st.execute(statements.get(0));
        if (!hasResult) {
          int updated = st.getUpdateCount();
          if (updated >= 0) {
            System.out.println("(" + updated + " row" + (updated == 1 ? "" : "s") + " affected)");
          } else {
            System.out.println("(no results)");
          }
          return;
        }
        try (ResultSet rs = st.getResultSet()) {
          printPage(rs, offset, size);
        }
      }
    } finally {
      if (streamed) {
        // A read needs no commit, and rolling back releases the cursor without
        // leaving the connection in a transaction for the next request.
        try {
          conn.rollback();
        } catch (SQLException e) {
          // nothing useful to do; the restore below is what matters
        }
        try {
          conn.setAutoCommit(autocommit);
        } catch (SQLException e) {
          // ditto
        }
      }
    }
  }

  private static void runOne(Connection conn, String sql) throws SQLException {
    try (Statement st = conn.createStatement()) {
      boolean hasResult = st.execute(sql);
      int statements = 0;
      do {
        statements++;
        if (hasResult) {
          try (ResultSet rs = st.getResultSet()) {
            printTable(rs);
          }
        } else {
          int updated = st.getUpdateCount();
          if (updated >= 0) {
            System.out.println("(" + updated + " row" + (updated == 1 ? "" : "s") + " affected)");
          }
        }
        hasResult = st.getMoreResults();
      } while (hasResult || st.getUpdateCount() != -1);
      if (statements == 0) System.out.println("(no results)");
    }
  }

  /**
   * One cell's text.
   *
   * <p>byte[] needs naming explicitly: String.valueOf(Object) on an array
   * yields a per-run identity hash like {@code [B@4cdbe50f}, so a BLOB column
   * showed a different meaningless value on every run.
   */
  private static String render(Object value) {
    if (value == null) return "NULL";
    if (value instanceof byte[] bytes) {
      StringBuilder sb = new StringBuilder("0x");
      int shown = Math.min(bytes.length, 16);
      for (int i = 0; i < shown; i++) sb.append(String.format("%02x", bytes[i]));
      if (bytes.length > shown) sb.append("…(").append(bytes.length).append(" bytes)");
      return sb.toString();
    }
    return String.valueOf(value);
  }

  /**
   * How many terminal columns `text` occupies.
   *
   * <p>String.length() counts UTF-16 units, so CJK and full-width text skewed
   * the grid this printer exists to produce: a 6-character cell can be 12
   * columns wide, and the separators for that row landed 6 columns out.
   */
  static int displayWidth(String text) {
    int width = 0;
    for (int i = 0; i < text.length(); ) {
      int cp = text.codePointAt(i);
      i += Character.charCount(cp);
      if (cp == 0 || Character.getType(cp) == Character.NON_SPACING_MARK) {
        continue;
      }
      width += isWide(cp) ? 2 : 1;
    }
    return width;
  }

  private static boolean isWide(int cp) {
    return (cp >= 0x1100 && cp <= 0x115F) // Hangul Jamo
        || (cp >= 0x2E80 && cp <= 0xA4CF && cp != 0x303F) // CJK, Kangxi, radicals
        || (cp >= 0xAC00 && cp <= 0xD7A3) // Hangul syllables
        || (cp >= 0xF900 && cp <= 0xFAFF) // CJK compatibility ideographs
        || (cp >= 0xFE30 && cp <= 0xFE6F) // CJK compatibility forms
        || (cp >= 0xFF00 && cp <= 0xFF60) // full-width forms
        || (cp >= 0xFFE0 && cp <= 0xFFE6)
        || (cp >= 0x1F300 && cp <= 0x1F64F) // emoji
        || (cp >= 0x1F900 && cp <= 0x1F9FF)
        || (cp >= 0x20000 && cp <= 0x3FFFD); // CJK extension planes
  }

  /** An aligned table, the way psql and sqlite3 -column print one. */
  /**
   * A result set held open across requests, read a batch at a time.
   *
   * <p>This is how a database IDE pages: the statement runs <em>once</em> and
   * successive batches come off the same cursor, streaming. Paging by
   * re-running the query with LIMIT/OFFSET -- which this layer did first --
   * executes the whole query again for every page, so walking a table is
   * quadratic, and under any concurrent write the pages do not line up with
   * each other: a row inserted before page 2 is fetched pushes a row from page
   * 1 onto page 2, and a deleted one hides a row entirely.
   *
   * <p>One cursor at a time, because that is what a result grid shows. Running
   * anything else on the connection closes it, which is also what a database
   * IDE does when you execute a new statement.
   *
   * <p>Only reachable in serve mode: a one-shot process exits between
   * requests, so there would be nothing to hold it open. kebab.dbide falls
   * back to LIMIT/OFFSET, and then to skipping on the cursor, when there is no
   * warm process.
   */
  private static final class Cursor {
    private static Statement statement;
    private static ResultSet rs;
    private static List<String> headers;
    private static List<String> pending; // read to answer "is there more?", not yet shown
    private static long handedOut;
    private static boolean autocommitRestore;
    private static Connection owner;

    static void handle(Connection conn, String arg, String sql) throws SQLException {
      String[] parts = (arg == null ? "" : arg).split(":", 2);
      String verb = parts.length > 0 ? parts[0].trim() : "";
      int size = 100;
      if (parts.length > 1 && !parts[1].isBlank()) {
        try {
          size = Integer.parseInt(parts[1].trim());
        } catch (NumberFormatException e) {
          throw new UsageException("cursor takes <verb>:<size>, got: " + arg);
        }
      }
      if (size < 1) {
        throw new UsageException("cursor size must be at least 1, got " + size);
      }
      switch (verb) {
        case "open" -> open(conn, sql, size);
        case "next" -> next(size);
        case "close" -> {
          close();
          System.out.println("(closed)");
        }
        default -> throw new UsageException("cursor verb must be open, next or close: " + verb);
      }
    }

    private static void open(Connection conn, String sql, int size) throws SQLException {
      close();
      if (sql == null || sql.isBlank()) {
        throw new UsageException("nothing to run");
      }
      List<String> statements = splitStatements(sql);
      if (statements.isEmpty()) {
        throw new UsageException("nothing to run");
      }
      if (statements.size() > 1) {
        throw new UsageException("paging needs a single statement, got " + statements.size());
      }

      // PostgreSQL's driver honours the fetch size only inside a transaction;
      // outside one it reads the entire result set before returning the first
      // row, which would defeat the whole arrangement.
      owner = conn;
      autocommitRestore = conn.getAutoCommit();
      if (autocommitRestore) {
        try {
          conn.setAutoCommit(false);
        } catch (SQLException e) {
          autocommitRestore = false; // nothing to restore
        }
      }

      Statement st = conn.createStatement(ResultSet.TYPE_FORWARD_ONLY, ResultSet.CONCUR_READ_ONLY);
      try {
        st.setFetchSize(size);
      } catch (SQLException e) {
        // advisory; a driver without it still works, just less lazily
      }
      boolean hasResult;
      try {
        hasResult = st.execute(statements.get(0));
      } catch (SQLException e) {
        st.close();
        release();
        throw e;
      }
      if (!hasResult) {
        int updated = st.getUpdateCount();
        st.close();
        release();
        System.out.println(
            updated >= 0
                ? "(" + updated + " row" + (updated == 1 ? "" : "s") + " affected)"
                : "(no results)");
        System.out.println("-- kebab-cursor shown=0 total=0 more=0 open=0");
        return;
      }
      statement = st;
      rs = st.getResultSet();
      ResultSetMetaData md = rs.getMetaData();
      headers = new ArrayList<>();
      for (int i = 1; i <= md.getColumnCount(); i++) headers.add(md.getColumnLabel(i));
      pending = null;
      handedOut = 0;
      emit(size);
    }

    private static void next(int size) throws SQLException {
      if (rs == null) {
        throw new UsageException("no result set is open; run the statement first");
      }
      emit(size);
    }

    /** Hand out up to `size` rows, and read one more to know whether to offer another page. */
    private static void emit(int size) throws SQLException {
      int cols = headers.size();
      List<List<String>> rows = new ArrayList<>();
      if (pending != null) {
        rows.add(pending);
        pending = null;
      }
      while (rows.size() < size && rs.next()) {
        rows.add(readRow(rs, cols));
      }
      // The probe row is kept, not discarded: having called next() it is ours,
      // and dropping it would skip a row at every page boundary.
      boolean more = rs.next();
      if (more) {
        pending = readRow(rs, cols);
      }
      handedOut += rows.size();

      StringBuilder sb = renderGrid(headers, rows);
      sb.append('\n').append('\n');
      if (rows.isEmpty()) {
        sb.append("(no more rows)");
      } else {
        sb.append("(")
            .append(rows.size())
            .append(rows.size() == 1 ? " row" : " rows")
            .append(more ? ", more to come)" : ", end of the result)");
      }
      sb.append('\n')
          .append("-- kebab-cursor shown=")
          .append(rows.size())
          .append(" total=")
          .append(handedOut)
          .append(" more=")
          .append(more ? 1 : 0)
          .append(" open=")
          .append(more ? 1 : 0);
      System.out.println(sb);
      if (!more) {
        close(); // nothing left to hold open
      }
    }

    static void close() {
      if (rs != null) {
        try {
          rs.close();
        } catch (SQLException e) {
          // closing is best effort
        }
      }
      if (statement != null) {
        try {
          statement.close();
        } catch (SQLException e) {
          // ditto
        }
      }
      release();
    }

    /** Give the connection back the way it was handed over. */
    private static void release() {
      rs = null;
      statement = null;
      headers = null;
      pending = null;
      if (owner != null && autocommitRestore) {
        try {
          owner.rollback(); // a read needs no commit; this frees the cursor
        } catch (SQLException e) {
          // nothing useful to do
        }
        try {
          owner.setAutoCommit(true);
        } catch (SQLException e) {
          // ditto
        }
      }
      autocommitRestore = false;
      owner = null;
    }
  }

  private static void printTable(ResultSet rs) throws SQLException {
    ResultSetMetaData md = rs.getMetaData();
    int cols = md.getColumnCount();
    List<String> headers = new ArrayList<>();
    for (int i = 1; i <= cols; i++) headers.add(md.getColumnLabel(i));

    List<List<String>> rows = new ArrayList<>();
    while (rs.next()) rows.add(readRow(rs, cols));

    StringBuilder sb = renderGrid(headers, rows);
    sb.append('\n').append('\n').append("(").append(rows.size())
        .append(rows.size() == 1 ? " row)" : " rows)");
    System.out.println(sb);
  }

  /**
   * One page of rows, with a footer the caller can parse.
   *
   * <p>The footer is how the editor knows whether there is a next page without
   * counting the whole result set: the cursor is asked for one row beyond the
   * page and that answer is reported. A count(*) would be a second query and
   * would disagree with the first under any concurrent write.
   */
  private static void printPage(ResultSet rs, long offset, int size) throws SQLException {
    ResultSetMetaData md = rs.getMetaData();
    int cols = md.getColumnCount();
    List<String> headers = new ArrayList<>();
    for (int i = 1; i <= cols; i++) headers.add(md.getColumnLabel(i));

    long skipped = 0;
    while (skipped < offset && rs.next()) skipped++;
    // Asking for a page past the end is not an error: it is what pressing
    // "next" on the last page does, and the footer says so.
    List<List<String>> rows = new ArrayList<>();
    while (rows.size() < size && rs.next()) rows.add(readRow(rs, cols));
    boolean more = rs.next();

    StringBuilder sb = renderGrid(headers, rows);
    sb.append('\n').append('\n');
    if (rows.isEmpty()) {
      sb.append(skipped < offset ? "(no rows at this offset)" : "(no rows)");
    } else {
      sb.append("(rows ")
          .append(offset + 1)
          .append("-")
          .append(offset + rows.size())
          .append(more ? " of more" : " of " + (offset + rows.size()))
          .append(")");
    }
    // Machine-readable, and last: kebab.dbide strips this line and renders the
    // pager from it.
    sb.append('\n')
        .append("-- kebab-page offset=")
        .append(offset)
        .append(" shown=")
        .append(rows.size())
        .append(" more=")
        .append(more ? 1 : 0);
    System.out.println(sb);
  }

  private static List<String> readRow(ResultSet rs, int cols) throws SQLException {
    List<String> row = new ArrayList<>(cols);
    for (int i = 1; i <= cols; i++) row.add(render(rs.getObject(i)));
    return row;
  }

  /** The aligned grid, without any footer. */
  private static StringBuilder renderGrid(List<String> headers, List<List<String>> rows) {
    int cols = headers.size();
    int[] width = new int[cols];
    for (int i = 0; i < cols; i++) width[i] = displayWidth(headers.get(i));
    for (List<String> row : rows) {
      for (int i = 0; i < cols; i++) width[i] = Math.max(width[i], displayWidth(row.get(i)));
    }

    StringBuilder sb = new StringBuilder();
    for (int i = 0; i < cols; i++) {
      if (i > 0) sb.append(" | ");
      sb.append(pad(headers.get(i), width[i]));
    }
    sb.append('\n');
    for (int i = 0; i < cols; i++) {
      if (i > 0) sb.append("-+-");
      sb.append("-".repeat(width[i]));
    }
    for (List<String> row : rows) {
      sb.append('\n');
      for (int i = 0; i < cols; i++) {
        if (i > 0) sb.append(" | ");
        sb.append(pad(row.get(i), width[i]));
      }
    }
    return sb;
  }

  private static String pad(String s, int w) {
    int width = displayWidth(s);
    if (width >= w) return s;
    return s + " ".repeat(w - width);
  }

  private static String readStdin() throws Exception {
    try (InputStream in = System.in) {
      ByteArrayOutputStream out = new ByteArrayOutputStream();
      byte[] buf = new byte[8192];
      int n;
      while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
      return out.toString(StandardCharsets.UTF_8).trim();
    }
  }
}
