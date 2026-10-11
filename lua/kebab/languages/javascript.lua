-- JavaScript and TypeScript. One language as far as the toolchain is concerned
-- -- vtsls serves both -- but the scaffolds have to offer both, which they did
-- not: every template was TypeScript-only.
local S = require("kebab.scaffold")

local VITE_TEMPLATES = {
  "react-ts", "react",
  "svelte-ts", "svelte",
  "vue-ts", "vue",
  "vanilla-ts", "vanilla",
  "preact-ts", "preact",
  "lit-ts", "lit",
  "solid-ts", "solid",
}

return {
  key = "javascript",
  label = "JavaScript / TypeScript",
  kind = "node",
  filetypes = { "javascript", "javascriptreact", "typescript", "typescriptreact" },

  markers = {
    {
      file = "package.json",
      kind = "node",
      deps = {
        prompt = "Package to add (npm): ",
        command = function(package, opts)
          local cmd = { "npm", "install" }
          if opts and opts.dev then
            table.insert(cmd, "--save-dev")
          end
          table.insert(cmd, package)
          return cmd
        end,
      },
    },
  },

  extras = {
    "lazyvim.plugins.extras.lang.typescript",
    "lazyvim.plugins.extras.linting.eslint",
  },
  tools = { "vtsls", "eslint-lsp", "prettier", "js-debug-adapter" },

  -- npm scripts come from overseer's builtin package.json provider, so only the
  -- ones it cannot know about are declared here.
  tasks = {
    { name = "npm: install", cmd = { "npm" }, args = { "install" }, desc = "Install dependencies", marker = "package.json" },
    { name = "npm: ci", cmd = { "npm" }, args = { "ci" }, desc = "Clean install from the lockfile", marker = "package.json" },
  },

  templates = {
    {
      name = "TypeScript module",
      extension = "ts",
      prompt = "Module name",
      filetypes = { "typescript", "javascript" },
      render = function() return { "export {};", "" } end,
    },
    {
      name = "JavaScript module",
      extension = "js",
      prompt = "Module name",
      filetypes = { "javascript", "typescript" },
      render = function() return { "export {};", "" } end,
    },
    {
      name = "React component (TSX)",
      extension = "tsx",
      prompt = "Component name",
      filetypes = { "typescriptreact", "typescript" },
      render = function(ctx)
        return {
          ("type %sProps = {"):format(ctx.name),
          "  children?: React.ReactNode;",
          "};",
          "",
          ("export function %s({ children }: %sProps) {"):format(ctx.name, ctx.name),
          "  return <div>{children}</div>;",
          "}",
          "",
        }
      end,
    },
    {
      name = "React component (JSX)",
      extension = "jsx",
      prompt = "Component name",
      filetypes = { "javascriptreact", "javascript" },
      render = function(ctx)
        return {
          ("export function %s({ children }) {"):format(ctx.name),
          "  return <div>{children}</div>;",
          "}",
          "",
        }
      end,
    },
    {
      name = "Vitest test file",
      extension = "test.ts",
      prompt = "Test file name",
      filetypes = { "typescript", "javascript" },
      default_name = function(current)
        return (current ~= nil and current ~= "") and current or nil
      end,
      render = function(ctx)
        return {
          'import { describe, expect, it } from "vitest";',
          "",
          ('describe("%s", () => {'):format(ctx.name),
          '  it("works", () => {',
          "    expect(true).toBe(true);",
          "  });",
          "});",
          "",
        }
      end,
    },
  },

  scratch = {
    { key = "ts", name = "TypeScript", extension = "ts", filetype = "typescript", lines = { 'console.log("hello");' } },
    { key = "js", name = "JavaScript", extension = "js", filetype = "javascript", lines = { 'console.log("hello");' } },
  },

  project_files = {
    {
      name = ".gitignore (Node)",
      file = ".gitignore",
      kinds = { "node" },
      lines = {
        "node_modules/", "dist/", "build/", ".vite/", ".svelte-kit/", ".next/",
        "*.tsbuildinfo", "coverage/",
        "", "# local config", ".env", ".env.local",
      },
    },
    {
      name = "Dockerfile (Node)",
      file = "Dockerfile",
      kinds = { "node" },
      lines = {
        "FROM node:22-alpine AS build",
        "WORKDIR /app",
        "# Copy the lockfile first so npm ci caches across source edits.",
        "COPY package*.json ./",
        "RUN npm ci",
        "COPY . .",
        "RUN npm run build --if-present",
        "",
        "FROM node:22-alpine",
        "WORKDIR /app",
        "ENV NODE_ENV=production",
        "COPY package*.json ./",
        "RUN npm ci --omit=dev && npm cache clean --force",
        "COPY --from=build /app/dist ./dist",
        "USER node",
        'CMD ["node", "dist/index.js"]',
      },
    },
    {
      name = "GitHub Actions (Node)",
      file = ".github/workflows/test.yml",
      kinds = { "node" },
      lines = {
        "name: test",
        "",
        "on:",
        "  push:",
        "    branches: [main]",
        "  pull_request:",
        "",
        "jobs:",
        "  test:",
        "    runs-on: ubuntu-latest",
        "    steps:",
        "      - uses: actions/checkout@v4",
        "      - uses: actions/setup-node@v4",
        "        with:",
        '          node-version: "22"',
        "          cache: npm",
        "      - run: npm ci",
        "      - run: npm run lint --if-present",
        "      - run: npm test --if-present",
      },
    },
  },

  project_types = {
    {
      key = "node",
      label = "Node (TypeScript or JavaScript)",
      requires = { "git", "npm" },
      prompts = {
        {
          name = "language",
          prompt = "Language",
          kind = "select",
          choices = { "typescript", "javascript" },
          default = "typescript",
        },
      },
      build = function(ctx, done)
        local ts = (ctx.answers.language or "typescript") == "typescript"
        local ext = ts and "ts" or "js"
        S.mkdir(ctx.dest .. "/src")
        S.write_file(ctx.dest .. "/src/index." .. ext, { 'console.log("hello");' })
        S.write_file(ctx.dest .. "/.gitignore", { "node_modules/", "dist/" })
        local steps = {
          { label = "git init", cmd = { "git", "init", "-q" } },
          { label = "npm init", cmd = { "npm", "init", "-y" } },
        }
        if ts then
          -- A tsconfig is what makes vtsls treat the project as TypeScript
          -- rather than guessing per file.
          S.write_file(ctx.dest .. "/tsconfig.json", {
            "{",
            '  "compilerOptions": {',
            '    "target": "ES2022",',
            '    "module": "ESNext",',
            '    "moduleResolution": "bundler",',
            '    "strict": true,',
            '    "outDir": "dist",',
            '    "rootDir": "src",',
            '    "esModuleInterop": true,',
            '    "skipLibCheck": true',
            "  },",
            '  "include": ["src"]',
            "}",
          })
          steps[#steps + 1] = {
            label = "npm install typescript",
            cmd = { "npm", "install", "--save-dev", "typescript", "@types/node" },
          }
        end
        S.run_steps(steps, ctx.dest, done)
      end,
    },
    {
      key = "vite",
      label = "Vite (React / Svelte / Vue / Solid, TS or JS)",
      requires = { "git", "npm" },
      network = true,
      prompts = {
        {
          name = "template",
          prompt = "Template",
          kind = "select",
          choices = VITE_TEMPLATES,
          default = "react-ts",
        },
      },
      build = function(ctx, done)
        local parent = S.parent_of(ctx.dest)
        local leaf = S.leaf_of(ctx.dest)
        S.mkdir(parent)
        S.run_steps({
          {
            label = "npm create vite",
            cmd = { "npm", "create", "vite@latest", leaf, "--", "--template", ctx.answers.template },
            cwd = parent,
          },
          { label = "npm install", cmd = { "npm", "install" }, cwd = ctx.dest },
          { label = "git init", cmd = { "git", "init", "-q" }, cwd = ctx.dest },
        }, parent, done)
      end,
    },
  },

  vite_templates = VITE_TEMPLATES,
}
