-- Java / Spring Boot tuning on top of lazyvim.plugins.extras.lang.java.
--
-- The stock extra wires jdtls + debugger + test runner but leaves the Eclipse
-- defaults in place. The settings below are the ones that close the visible
-- gaps against a graphical IDE on a Maven/Spring project: real library sources on
-- "go to definition", code lenses for references/implementations, and static
-- import completion for the JUnit/Mockito/MockMvc helpers.
return {
  {
    "mfussenegger/nvim-jdtls",
    opts = function(_, opts)
      opts.settings = vim.tbl_deep_extend("force", opts.settings or {}, {
        java = {
          configuration = {
            -- Pick up pom.xml changes without a manual reload (Maven
            -- auto-import).
            updateBuildConfiguration = "automatic",
            runtimes = require("kebab.jdk").runtimes(),
          },
          -- Without these, jumping into Spring/third-party classes lands in
          -- decompiled stubs instead of the real source.
          maven = { downloadSources = true },
          eclipse = { downloadSources = true },
          references = { includeDecompiledSources = true },
          contentProvider = { preferred = "fernflower" },

          implementationsCodeLens = { enabled = true },
          referencesCodeLens = { enabled = true },
          signatureHelp = { enabled = true, description = { enabled = true } },
          inlayHints = { parameterNames = { enabled = "all" } },
          format = { enabled = true },

          completion = {
            importOrder = { "java", "javax", "jakarta", "com", "org" },
            favoriteStaticMembers = {
              "org.junit.jupiter.api.Assertions.*",
              "org.junit.jupiter.api.Assumptions.*",
              "org.assertj.core.api.Assertions.*",
              "org.mockito.Mockito.*",
              "org.mockito.ArgumentMatchers.*",
              "org.mockito.BDDMockito.*",
              "org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*",
              "org.springframework.test.web.servlet.result.MockMvcResultMatchers.*",
              "java.util.Objects.requireNonNull",
              "java.util.Objects.requireNonNullElse",
            },
          },
          sources = {
            organizeImports = { starThreshold = 9999, staticStarThreshold = 9999 },
          },
        },
      })

      -- Append the Spring Boot language-server jars to jdtls' bundles without
      -- clobbering the java-debug / java-test bundles the extra already set.
      -- opts.jdtls may be a function; LazyVim calls it with the built config.
      opts.jdtls = function(config)
        local ok, sb = pcall(require, "spring_boot")
        if ok then
          config.init_options = config.init_options or {}
          local bundles = config.init_options.bundles or {}
          vim.list_extend(bundles, sb.java_extensions())
          config.init_options.bundles = bundles
        end
        return config
      end

      return opts
    end,
  },

  -- Spring-specific intelligence jdtls alone does not have: completion in
  -- application.properties / application.yml resolved against your own beans,
  -- bean and request-mapping navigation, live actuator data.
  {
    "JavaHello/spring-boot.nvim",
    ft = { "java", "yaml", "jproperties" },
    dependencies = { "mfussenegger/nvim-jdtls" },
    opts = {},
  },
}
