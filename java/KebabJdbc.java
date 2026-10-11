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
      System.err.println("columns needs a table name");
      System.exit(2);
    }
    String schema = null;
    String name = table;
    int dot = table.lastIndexOf('.');
    if (dot > 0) {
      schema = table.substring(0, dot);
      name = table.substring(dot + 1);
    }
    DatabaseMetaData md = conn.getMetaData();
    try (ResultSet rs = md.getColumns(null, schema, name, "%")) {
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
      try (ResultSet rs = md.getColumns(null, schema, name, "%")) {
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

  private static void query(Connection conn, String sql) throws SQLException {
    if (sql.isBlank()) {
      System.err.println("nothing to run");
      System.exit(2);
    }
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
        row.add(value == null ? "NULL" : String.valueOf(value));
      }
      rows.add(row);
    }

    int[] width = new int[cols];
    for (int i = 0; i < cols; i++) width[i] = headers.get(i).length();
    for (List<String> row : rows) {
      for (int i = 0; i < cols; i++) width[i] = Math.max(width[i], row.get(i).length());
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
    if (s.length() >= w) return s;
    return s + " ".repeat(w - s.length());
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
