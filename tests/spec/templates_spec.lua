-- File templates, and the path arithmetic that makes them worth having.
local H = ...
local T = require("kebab.templates")
local registry = require("kebab.registry")

H.describe("deriving the Java package from the directory", function()
  H.it("reads it off a Maven main source root", function()
    H.eq("com.example.thing", T.package_for("/p/src/main/java/com/example/thing"))
  end)

  H.it("reads it off a test source root", function()
    H.eq("com.example.thing", T.package_for("/p/src/test/java/com/example/thing"))
  end)

  H.it("handles Kotlin and Groovy roots", function()
    H.eq("com.x", T.package_for("/p/src/main/kotlin/com/x"))
    H.eq("com.x", T.package_for("/p/src/test/groovy/com/x"))
  end)

  H.it("is empty at the source root itself", function()
    H.eq("", T.package_for("/p/src/main/java"))
    H.eq("", T.package_for("/p/src/main/java/"))
  end)

  H.it("is empty outside any source root", function()
    H.eq("", T.package_for("/p/random/dir"))
    H.eq("", T.package_for("/"))
  end)

  H.it("is not fooled by a directory that merely ends in src", function()
    H.eq("", T.package_for("/p/mysrc/main/javax/com/x"),
      "only a real src/main/java segment counts")
  end)

  H.it("keeps a deep package intact", function()
    H.eq("com.example.shop.orders",
      T.package_for("/p/src/main/java/com/example/shop/orders"))
  end)
end)

H.describe("redirecting a test template to the test root", function()
  H.it("swaps main for test, keeping the package", function()
    H.eq("/p/src/test/java/com/x", T.test_dir_for("/p/src/main/java/com/x"))
  end)

  H.it("leaves a test directory alone", function()
    H.eq("/p/src/test/java/com/x", T.test_dir_for("/p/src/test/java/com/x"))
  end)

  H.it("handles the bare source root", function()
    H.eq("/p/src/test/java", T.test_dir_for("/p/src/main/java"))
  end)

  H.it("handles Kotlin", function()
    H.eq("/p/src/test/kotlin/com/x", T.test_dir_for("/p/src/main/kotlin/com/x"))
  end)

  H.it("leaves an unrelated directory alone", function()
    H.eq("/p/lib", T.test_dir_for("/p/lib"))
  end)
end)

H.describe("template paths", function()
  local function template(extra)
    return vim.tbl_extend("force", { name = "t", extension = "java", render = function() return {} end }, extra or {})
  end

  H.it("adds the extension when the user leaves it off", function()
    H.eq("/d/Thing.java", T.path_for(template(), "/d", "Thing"))
  end)

  H.it("does not double the extension", function()
    H.eq("/d/Thing.java", T.path_for(template(), "/d", "Thing.java"))
  end)

  H.it("tolerates a trailing slash on the directory", function()
    H.eq("/d/Thing.java", T.path_for(template(), "/d/", "Thing"))
  end)

  H.it("allows a nested name", function()
    H.eq("/d/sub/Thing.java", T.path_for(template(), "/d", "sub/Thing"))
  end)
end)

H.describe("creating a file from a template", function()
  local function java_template(name)
    for _, t in ipairs(registry.templates()) do
      if t.name == name then return t end
    end
    error("no template named " .. name, 2)
  end

  H.it("writes a Java class with the package filled in from the directory", function()
    local root = H.tmpdir("tmpl-java")
    local dir = root .. "/src/main/java/io/gulay/thing"
    vim.fn.mkdir(dir, "p")
    local ok, path = T.create(java_template("Java class"), dir, "Widget", { open = false })
    H.ok(ok, tostring(path))
    H.eq(dir .. "/Widget.java", path)
    local text = H.read(path)
    H.matches("^package io%.gulay%.thing;", text)
    H.matches("public class Widget {", text)
  end)

  H.it("omits the package line outside a source root", function()
    local dir = H.tmpdir("tmpl-nopkg")
    local ok, path = T.create(java_template("Java class"), dir, "Loose", { open = false })
    H.ok(ok, tostring(path))
    local text = H.read(path)
    H.falsy(text:match("package"), "there is no package to declare: " .. text)
    H.matches("public class Loose {", text)
  end)

  H.it("writes a record, an interface and an enum", function()
    local dir = H.tmpdir("tmpl-shapes") .. "/src/main/java/a/b"
    vim.fn.mkdir(dir, "p")
    for name, pattern in pairs({
      ["Java record"] = "public record Shape%(%) {",
      ["Java interface"] = "public interface Shape2 {",
      ["Java enum"] = "public enum Shape3 {",
      ["Java abstract class"] = "public abstract class Shape4 {",
    }) do
      local target = name == "Java record" and "Shape"
        or name == "Java interface" and "Shape2"
        or name == "Java enum" and "Shape3"
        or "Shape4"
      local ok, path = T.create(java_template(name), dir, target, { open = false })
      H.ok(ok, tostring(path))
      H.matches(pattern, H.read(path), name)
      H.matches("^package a%.b;", H.read(path), name .. " needs the package line")
    end
  end)

  H.it("puts a JUnit test under src/test/java with the same package", function()
    -- The backlog's "test class for the file you are on".
    local root = H.tmpdir("tmpl-test")
    local main = root .. "/src/main/java/io/gulay/svc"
    vim.fn.mkdir(main, "p")
    local ok, path = T.create(java_template("JUnit 5 test class"), main, "WidgetTest", { open = false })
    H.ok(ok, tostring(path))
    H.eq(root .. "/src/test/java/io/gulay/svc/WidgetTest.java", path,
      "it should be redirected to the test root")
    local text = H.read(path)
    H.matches("^package io%.gulay%.svc;", text)
    H.matches("import org%.junit%.jupiter%.api%.Test;", text)
    H.matches("class WidgetTest {", text)
  end)

  H.it("suggests FooTest for Foo, and does not double the suffix", function()
    local t = java_template("JUnit 5 test class")
    H.eq("WidgetTest", t.default_name("Widget"))
    H.eq("WidgetTest", t.default_name("WidgetTest"))
    H.eq(nil, t.default_name(""))
  end)

  H.it("writes Spring stereotypes with their annotations", function()
    local dir = H.tmpdir("tmpl-spring") .. "/src/main/java/io/gulay/web"
    vim.fn.mkdir(dir, "p")
    local _, controller = T.create(java_template("Spring @RestController"), dir, "ThingController", { open = false })
    H.matches("@RestController", H.read(controller))
    H.matches("@RequestMapping", H.read(controller))
    local _, service = T.create(java_template("Spring @Service"), dir, "ThingService", { open = false })
    H.matches("@Service", H.read(service))
    H.matches("^package io%.gulay%.web;", H.read(service))
  end)

  H.it("uses the directory name as the Go package", function()
    local dir = H.tmpdir("tmpl-go") .. "/internal/store"
    vim.fn.mkdir(dir, "p")
    local ok, path = T.create(java_template("Go file"), dir, "store", { open = false })
    H.ok(ok, tostring(path))
    H.matches("^package store", H.read(path))
  end)

  H.it("writes a Go test with the testing import", function()
    local dir = H.tmpdir("tmpl-gotest") .. "/pkg/thing"
    vim.fn.mkdir(dir, "p")
    local _, path = T.create(java_template("Go test file"), dir, "thing_test", { open = false })
    H.matches("^package thing", H.read(path))
    H.matches('import "testing"', H.read(path))
    H.matches("func TestTodo%(t %*testing%.T%)", H.read(path))
  end)

  H.it("writes a pytest module named test_*", function()
    local t = java_template("pytest test module")
    H.eq("test_widget", t.default_name("widget"))
    H.eq("test_widget", t.default_name("test_widget"))
    local dir = H.tmpdir("tmpl-py")
    local _, path = T.create(t, dir, "test_widget", { open = false })
    H.matches("def test_todo", H.read(path))
  end)

  H.it("writes React components in both TSX and JSX", function()
    local dir = H.tmpdir("tmpl-react")
    local _, tsx = T.create(java_template("React component (TSX)"), dir, "Card", { open = false })
    H.matches("Card%.tsx$", tsx)
    H.matches("type CardProps", H.read(tsx))
    local _, jsx = T.create(java_template("React component (JSX)"), dir, "Card", { open = false })
    H.matches("Card%.jsx$", jsx)
    H.matches("export function Card", H.read(jsx))
    H.falsy(H.read(jsx):match("Props"), "the JavaScript one should have no types")
  end)

  H.it("writes a Svelte component", function()
    local dir = H.tmpdir("tmpl-svelte")
    local _, path = T.create(java_template("Svelte component"), dir, "ThingPanel", { open = false })
    H.matches("ThingPanel%.svelte$", path)
    H.matches("<script lang=\"ts\">", H.read(path))
  end)

  H.it("refuses to overwrite an existing file", function()
    local dir = H.tmpdir("tmpl-clash")
    H.write(dir .. "/Taken.java", "mine")
    local ok, err = T.create(java_template("Java class"), dir, "Taken", { open = false })
    H.falsy(ok)
    H.matches("already exists", err)
    H.eq("mine", H.read(dir .. "/Taken.java"), "the existing file must survive")
  end)

  H.it("requires a name", function()
    local dir = H.tmpdir("tmpl-noname")
    for _, bad in ipairs({ "", "   " }) do
      local ok, err = T.create(java_template("Java class"), dir, bad, { open = false })
      H.falsy(ok)
      H.matches("name is required", err)
    end
  end)

  H.it("creates intermediate directories", function()
    local dir = H.tmpdir("tmpl-deep")
    local ok, path = T.create(java_template("Java class"), dir, "a/b/c/Deep", { open = false })
    H.ok(ok, tostring(path))
    H.ok(H.exists(dir .. "/a/b/c/Deep.java"))
  end)
end)

H.describe("template registration", function()
  H.it("every template is usable", function()
    for _, t in ipairs(registry.templates()) do
      H.ok(type(t.name) == "string" and t.name ~= "", "a template needs a name")
      H.ok(type(t.extension) == "string" and t.extension ~= "", t.name .. " needs an extension")
      H.ok(type(t.render) == "function", t.name .. " needs a render function")
      H.ok(type(t.language) == "string", t.name .. " should be tagged with its language")
    end
  end)

  H.it("every template renders a non-empty file", function()
    local dir = H.tmpdir("tmpl-all") .. "/src/main/java/x/y"
    vim.fn.mkdir(dir, "p")
    for _, t in ipairs(registry.templates()) do
      local ctx = T.context(t, dir, "Sample")
      local lines = T.render(t, ctx)
      H.ok(type(lines) == "table" and #lines > 0, t.name .. " rendered nothing")
      for i, line in ipairs(lines) do
        H.ok(type(line) == "string", ("%s line %d is not a string"):format(t.name, i))
        H.falsy(line:match("\n"), ("%s line %d contains a newline; writefile needs separate lines"):format(t.name, i))
      end
    end
  end)

  H.it("filters by filetype", function()
    local java = T.available({ filetype = "java" })
    H.ok(#java >= 5, "expected several Java templates")
    for _, t in ipairs(java) do
      H.ok(vim.tbl_contains(t.filetypes, "java"), t.name .. " should apply to java")
    end
    local svelte = T.available({ filetype = "svelte" })
    H.ok(#svelte >= 1)
  end)

  H.it("registers :IdeNewFile", function()
    H.ok(vim.fn.exists(":IdeNewFile") >= 1)
  end)
end)

H.describe("the template picker", function()
  H.it("asks for a template, then a name, then writes the file", function()
    local root = H.tmpdir("tmpl-pick")
    local dir = root .. "/src/main/java/io/gulay/pick"
    vim.fn.mkdir(dir, "p")
    local ui = H.with_ui({ "Java class", "Picked" }, function()
      H.capture_notify(function()
        T.pick({ dir = dir, filetype = "java" })
      end)
    end)
    H.eq(2, ui.consumed())
    H.ok(H.exists(dir .. "/Picked.java"), "the file should have been written")
    H.matches("package io%.gulay%.pick;", H.read(dir .. "/Picked.java"))
    vim.cmd("bwipeout!")
  end)

  H.it("shows the package it will use in the picker", function()
    local dir = H.tmpdir("tmpl-label") .. "/src/main/java/io/gulay/lbl"
    vim.fn.mkdir(dir, "p")
    local labels
    local orig = vim.ui.select
    vim.ui.select = function(items, opts)
      labels = vim.tbl_map(function(i) return opts.format_item(i) end, items)
    end
    T.pick({ dir = dir, filetype = "java" })
    vim.ui.select = orig
    H.ok(labels and #labels > 0, "the picker should have been offered items")
    H.matches("io%.gulay%.lbl", table.concat(labels, "\n"),
      "the package should be visible before you commit to it")
  end)

  H.it("does nothing when cancelled", function()
    local dir = H.tmpdir("tmpl-cancel")
    H.with_ui({ H.CANCEL }, function()
      H.capture_notify(function() T.pick({ dir = dir, filetype = "java" }) end)
    end)
    H.eq({}, vim.fn.readdir(dir), "nothing should have been written")
  end)
end)
