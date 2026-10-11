-- The web frameworks on top of JavaScript: Svelte and Tailwind. Kept separate
-- from javascript.lua because they are frameworks, not the language, and a user
-- who wants neither can drop this one alone through
-- vim.g.kebab_disabled_languages.
return {
  key = "web",
  label = "Svelte / Tailwind",
  kind = "node",
  filetypes = { "svelte", "css", "scss", "html" },

  -- No markers: a Svelte project is still a node project by package.json, and
  -- javascript.lua claims that. Declaring it here too would only shadow it.
  markers = {},

  extras = {
    "lazyvim.plugins.extras.lang.svelte",
    "lazyvim.plugins.extras.lang.tailwind",
    "lazyvim.plugins.extras.formatting.prettier",
  },
  tools = { "svelte-language-server", "tailwindcss-language-server" },

  templates = {
    {
      name = "Svelte component",
      extension = "svelte",
      prompt = "Component name",
      filetypes = { "svelte" },
      render = function(ctx)
        return {
          '<script lang="ts">',
          ("  // %s"):format(ctx.name),
          "</script>",
          "",
          ("<div class=\"%s\">"):format((ctx.name:gsub("(%l)(%u)", "%1-%2"):lower())),
          ("  <slot />"),
          "</div>",
          "",
          "<style>",
          "</style>",
          "",
        }
      end,
    },
    {
      name = "SvelteKit +page.svelte",
      extension = "svelte",
      prompt = "Route directory (blank for here)",
      filetypes = { "svelte" },
      -- SvelteKit routes a file only when its name starts with "+", so the
      -- answer names a directory. Feeding it to the file name produced
      -- `about.svelte`, which SvelteKit ignores entirely.
      blank_name_ok = true,
      relative_path = function(name)
        local route = vim.trim(name or ""):gsub("^/+", ""):gsub("/+$", "")
        if route == "" then
          return "+page.svelte"
        end
        if route:match("%+[%w%-%.]+%.svelte$") then
          return route
        end
        return route .. "/+page.svelte"
      end,
      render = function()
        return {
          '<script lang="ts">',
          "</script>",
          "",
          "<h1>Page</h1>",
          "",
        }
      end,
    },
  },
}
