{Emitter} = require 'emissary'

utilGhcMod = require './util-ghc-mod'


class CompletionDatabase

  constructor: (@manager) ->
    Emitter.extend(this)
    @modules = {}

  # Remove obsolete imports - which not in provided list
  removeObsolete: (imports) ->
    for module, v of @modules
      delete @modules[module] if imports.indexOf(module) is -1

  # Update module symbols.
  # This function updates module symbols if module does not present in
  # module list. If module is in list, merely return true.
  update: (fileName, moduleName) ->
    return true if @modules[moduleName]?
    @_update fileName, moduleName
    return true

  # Real module update
  _update: (fileName, moduleName) ->
    @modules[moduleName] = []
    @manager.pendingProcessController.start utilGhcMod.browse, {
      fileName: fileName
      moduleName: moduleName
      onResult: (result) => @modules[moduleName]?.push result
    }


class MainCompletionDatabase extends CompletionDatabase
  constructor: (@manager) ->
    super(@manager)
    @rebuild()

  reset: ->
    @readyCounter = 0
    @rebuildActive = true
    @ready = false
    @extensions = []
    @ghcFlags = []
    @modules = {}

  # Build this database
  rebuild: ->
    return if @rebuildActive
    @reset()

    # TODO run ghc-mod lang and flag

    # run ghc-mod list to get all module dependencies
    @manager.pendingProcessController.start utilGhcMod.list, {
      onResult: (result) => @modules[result] = null
      onComplete: => @updateReadyCounter()
    }

  # Increase ready counter
  updateReadyCounter: ->
    @readyCounter++
    return unless @readyCounter is 1

    # set database ready and emmit ready event
    @rebuildActive = false
    @ready = true

    # emit ready event
    @emit 'database-updated'

  # Update module symbols.
  # In main database we got another behaviour. If module is not preset,
  # return false. If present and null, then update. And if not null, then
  # simply return true.
  update: (fileName, moduleName) ->
    return false if @modules[moduleName] is undefined
    return true if @modules[moduleName] isnt null
    @_update fileName, moduleName
    return true


module.exports = {
  CompletionDatabase,
  MainCompletionDatabase
}
