--- Telescope extension: `:Telescope sshdev` lists remembered connections.
---
--- Loaded by telescope only when the user calls it, so telescope stays an
--- optional dependency:
---   require('telescope').load_extension('sshdev')
---   require('telescope').extensions.sshdev.connections()

return require('telescope').register_extension({
  exports = {
    sshdev = function(opts)
      local Picker = require('sshdev.picker')
      local cfg = require('sshdev.config').get()
      Picker.select(cfg, function(entry)
        if not entry then
          return
        end
        require('sshdev.session').connect({
          dest = entry.dest,
          workspace = entry.workspace,
          force = opts and opts.force or false,
        })
      end)
    end,
    connections = function(opts)
      local Picker = require('sshdev.picker')
      local cfg = require('sshdev.config').get()
      Picker.select(cfg, function(entry)
        if not entry then
          return
        end
        require('sshdev.session').connect({
          dest = entry.dest,
          workspace = entry.workspace,
          force = opts and opts.force or false,
        })
      end)
    end,
  },
})
