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
import java.util.Enumeration;
import java.util.List;
import java.util.Properties;

public final class KebabJdbc {

  public static void main(String[] args) {
    if (args.length < 2) {
      System.err.println("usage: KebabJdbc <mode> <jdbc-url> [args...]");
      System.exit(2);
    }
    String mode = args[0];
    String url = args[1];

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
        case "schema" -> schema(conn);
        case "query" -> query(conn, readStdin());
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
      String[] parts = header.split("\t", -1);
      if (parts.length < 3) {
        respond(out, false, "malformed request header");
        continue;
      }
      String mode = parts[0];
      String arg = parts[1];
      int length;
      try {
        length = Integer.parseInt(parts[2].trim());
      } catch (NumberFormatException e) {
        respond(out, false, "malformed payload length");
        continue;
      }
      String payload = readExactly(in, length);
      if (payload == null) {
        return;
      }
      if (mode.equals("close")) {
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
        case "schema" -> schema(conn);
        case "query" -> query(conn, payload);
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
    try (ResultSet rs = md.getTables(null, null, "%", new String[] {"TABLE", "VIEW"})) {
      while (rs.next()) {
        String schema = rs.getString("TABLE_SCHEM");
        String name = rs.getString("TABLE_NAME");
        System.out.println(qualify(schema, name));
      }
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
  private static void schema(Connection conn) throws SQLException {
    DatabaseMetaData md = conn.getMetaData();
    List<String> names = new ArrayList<>();
    try (ResultSet rs = md.getTables(null, null, "%", new String[] {"TABLE", "VIEW"})) {
      while (rs.next()) {
        names.add(qualify(rs.getString("TABLE_SCHEM"), rs.getString("TABLE_NAME")));
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
  private static void printTable(ResultSet rs) throws SQLException {
    ResultSetMetaData md = rs.getMetaData();
    int cols = md.getColumnCount();
    List<String> headers = new ArrayList<>();
    for (int i = 1; i <= cols; i++) headers.add(md.getColumnLabel(i));

    List<List<String>> rows = new ArrayList<>();
    while (rs.next()) {
      List<String> row = new ArrayList<>(cols);
      for (int i = 1; i <= cols; i++) {
        Object value = rs.getObject(i);
        row.add(render(value));
      }
      rows.add(row);
    }

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
    sb.append('\n').append('\n').append("(").append(rows.size())
        .append(rows.size() == 1 ? " row)" : " rows)");
    System.out.println(sb);
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
