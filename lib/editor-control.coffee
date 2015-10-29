SubAtom = require 'sub-atom'

{bufferPositionFromMouseEvent} = require './utils'
{TooltipMessage} = require './views/tooltip-view'
{Range, Disposable, Emitter} = require 'atom'

class EditorControl
  constructor: (@editor) ->
    @disposables = new SubAtom
    @disposables.add @emitter = new Emitter

    @editorElement = atom.views.getView(@editor).rootElement

    unless atom.config.get 'ide-haskell.useLinter'
      @gutter = @editor.gutterWithName "ide-haskell-check-results"
      @gutter ?= @editor.addGutter
        name: "ide-haskell-check-results"
        priority: 10

      gutterElement = atom.views.getView(@gutter)
      @disposables.add gutterElement, 'mouseenter', ".decoration", (e) =>
        bufferPt = bufferPositionFromMouseEvent @editor, e
        @lastMouseBufferPt = bufferPt
        @showCheckResult bufferPt, true
      @disposables.add gutterElement, 'mouseleave', ".decoration", (e) =>
        @hideTooltip()

    # buffer events for automatic check
    buffer = @editor.getBuffer()
    editorElement = atom.views.getView(@editor)
    @disposables.add buffer.onWillSave =>
      @emitter.emit 'will-save-buffer', buffer
      if atom.config.get('ide-haskell.onSavePrettify')
        atom.commands.dispatch editorElement, 'ide-haskell:prettify-file'

    @disposables.add buffer.onDidSave =>
      @emitter.emit 'did-save-buffer', buffer

    @disposables.add @editor.onDidStopChanging =>
      @emitter.emit 'did-stop-changing', @editor

    # show expression type if mouse stopped somewhere
    @disposables.add @editorElement, 'mousemove', '.scroll-view', (e) =>
      bufferPt = bufferPositionFromMouseEvent @editor, e

      return if @lastMouseBufferPt?.isEqual(bufferPt)
      @lastMouseBufferPt = bufferPt

      @clearExprTypeTimeout()
      @exprTypeTimeout = setTimeout (=> @shouldShowTooltip bufferPt),
        atom.config.get('ide-haskell.expressionTypeInterval')
    @disposables.add @editorElement, 'mouseout', '.scroll-view', (e) =>
      @clearExprTypeTimeout()

    @disposables.add @editor.onDidChangeCursorPosition ({newBufferPosition}) =>
      switch atom.config.get('ide-haskell.onCursorMove')
        when 'Show Tooltip'
          @clearExprTypeTimeout()
          @showCheckResult newBufferPosition, false, 'keyboard'
        when 'Hide Tooltip'
          @clearExprTypeTimeout()
          @hideTooltip()

  deactivate: ->
    @clearExprTypeTimeout()
    @hideTooltip()
    @disposables.dispose()
    @disposables = null
    @editorElement = null
    @editor = null
    @lastMouseBufferPt = null

  # helper function to hide tooltip and stop timeout
  clearExprTypeTimeout: ->
    if @exprTypeTimeout?
      clearTimeout @exprTypeTimeout
      @exprTypeTimeout = null

  updateResults: (res, types) =>
    if types?
      for t in types
        m.destroy() for m in @editor.findMarkers {type: 'check-result', severity: t}
    else
      m.destroy() for m in @editor.findMarkers {type: 'check-result'}
    @markerFromCheckResult(r) for r in res

  markerFromCheckResult: ({uri, severity, message, position}) ->
    return unless uri? and uri is @editor.getURI()

    # create a new marker
    range = new Range position, {row: position.row, column: position.column + 1}
    marker = @editor.markBufferRange range,
      type: 'check-result'
      severity: severity
      desc: message

    @decorateMarker(marker)

  decorateMarker: (m) ->
    return unless @gutter?
    cls = 'ide-haskell-' + m.getProperties().severity
    @gutter.decorateMarker m, type: 'line-number', class: cls
    @editor.decorateMarker m, type: 'highlight', class: cls
    @editor.decorateMarker m, type: 'line', class: cls

  onShouldShowTooltip: (callback) ->
    @emitter.on 'should-show-tooltip', callback

  onWillSaveBuffer: (callback) ->
    @emitter.on 'will-save-buffer', callback

  onDidSaveBuffer: (callback) ->
    @emitter.on 'did-save-buffer', callback

  onDidStopChanging: (callback) ->
    @emitter.on 'did-stop-changing', callback

  shouldShowTooltip: (pos) ->
    return if @showCheckResult pos

    if pos.row < 0 or
       pos.row >= @editor.getLineCount() or
       pos.isEqual @editor.bufferRangeForBufferRow(pos.row).end
      @hideTooltip 'mouse'
    else
      @emitter.emit 'should-show-tooltip', {@editor, pos}

  showTooltip: (pos, range, text, eventType) ->
    return unless @editor?

    if range.isEqual(@tooltipHighlightRange)
      return
    @hideTooltip()
    #exit if mouse moved away
    if eventType is 'mouse'
      unless range.containsPoint(@lastMouseBufferPt)
        return
    @tooltipHighlightRange = range
    @markerBufferRange = range
    markerPos =
      switch eventType
        when 'keyboard' then pos
        else range.start
    tooltipMarker = @editor.markBufferPosition markerPos,
      type: 'tooltip'
      eventType: eventType
    highlightMarker = @editor.markBufferRange range,
      type: 'tooltip'
      eventType: eventType
    @editor.decorateMarker tooltipMarker,
      type: 'overlay'
      item: new TooltipMessage text
    @editor.decorateMarker highlightMarker,
      type: 'highlight'
      class: 'ide-haskell-type'

  hideTooltip: (eventType) ->
    @tooltipHighlightRange = null
    template = type: 'tooltip'
    if eventType?
      template.eventType = eventType
    m.destroy() for m in @editor.findMarkers template

  getEventRange: (pos, eventType) ->
    switch eventType
      when 'mouse', 'context'
        pos ?= @lastMouseBufferPt
        [selRange] = @editor.getSelections()
          .map (sel) ->
            sel.getBufferRange()
          .filter (sel) ->
            sel.containsPoint pos
        crange = selRange ? Range.fromPointWithDelta(pos, 0, 0)
      when 'keyboard'
        crange = @editor.getLastSelection().getBufferRange()
        pos = crange.start
      else
        throw new Error "unknown event type #{eventType}"

    return {crange, pos}

  findCheckResultMarkers: (pos, gutter, keyboard) ->
    if gutter
      @editor.findMarkers {type: 'check-result', startBufferRow: pos.row}
    else if keyboard
      @editor.findMarkers {type: 'check-result', containsRange: Range.fromPointWithDelta pos, 0, 1}
    else
      @editor.findMarkers {type: 'check-result', containsPoint: pos}

  # show check result when mouse over gutter icon
  showCheckResult: (pos, gutter, eventType = 'mouse') ->
    markers = @findCheckResultMarkers pos, gutter, eventType is 'keyboard'
    [marker] = markers

    unless marker?
      @hideTooltip(eventType) if @checkResultShowing
      @checkResultShowing = false
      return false

    text = (markers.map (marker) ->
      marker.getProperties().desc).join('\n\n')

    if gutter
      @showTooltip pos, new Range(pos, pos), text, eventType
    else
      @showTooltip pos, marker.getBufferRange(), text, eventType

    @checkResultShowing = true
    return true

  hasTooltips: ->
    !!@editor.findMarkers(type: 'tooltip').length

module.exports = {
  EditorControl
}
