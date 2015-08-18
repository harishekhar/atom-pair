require '../pusher/pusher'
require '../pusher/pusher-js-client-auth'
{CompositeDisposable, Emitter} = require 'atom'
AtomPairConfig = require './atom_pair_config'
MessageQueue = require './message_queue'
SharePane = require './share_pane'
User = require './user'
InputView = require '../views/input-view'
randomstring = require 'randomstring'
_ = require 'underscore'

module.exports =
class Session

  @initiate: (invitationMethod)->
    session = @active ? new Session
    new invitationMethod(session)

  @join: ->
    if @active
      atom.notifications.addError "It looks like you are already in a pairing session. Please open a new window (cmd+shift+N) to start/join a new one."
      return
    session = new Session
    joinView = new InputView("Enter the session ID here:")

    joinView.onInput (text) =>
      session.id = text
      keys = session.id.split("-")
      [session.app_key, session.app_secret] = [keys[0], keys[1]]
      joinView.panel.hide()
      session.pairingSetup()

  constructor: ->
    _.extend(@, AtomPairConfig)
    @triggerPush = @engageTabListener = true
    @subscriptions = new CompositeDisposable
    SharePane.globalEmitter = new Emitter

  end: ->
    @pusher.disconnect()
    _.each @friendColours, (colour) => SharePane.each (pane) -> pane.clearMarkers(colour)
    SharePane.all = []
    SharePane.globalEmitter.dispose()
    @subscriptions.dispose()
    @queue.dispose()
    @markerColour = null
    @friendColours = []
    @id = null
    @membersCount = null
    @leaderColour = null
    @active = false
    @constructor.active = null
    atom.notifications.addWarning("You have been disconnected.")

  generateId: ->
    @id ?= "#{@app_key}-#{@app_secret}-#{randomstring.generate(11)}"

  pairingSetup: ->
    @connectToPusher()
    @getExistingMembers()

  connectToPusher: ->
    colour = User.me?.colour
    arrivalTime = User.me?.arrivalTime

    @pusher = new Pusher @app_key,
      authTransport: 'client'
      clientAuth:
        key: @app_key
        secret: @app_secret
        user_id: colour || "blank"
        user_info:
          arrivalTime: arrivalTime || "blank"
    @queue = new MessageQueue(@pusher)
    @channel = @pusher.subscribe("presence-session-#{@id}")

  getExistingMembers: ->
    @channel.bind 'pusher:subscription_succeeded', (members) =>
      members.each (member) ->
        return if User.withColour(member.id) or member.id is "blank"
        User.add(member.id, member.arrivalTime)
        _.each User.allButMe(), (user) ->
          SharePane.each (pane) -> pane.addMarker 0, user.colour
      return @resubscribe() unless User.me
      @startPairing()

  resubscribe: ->
    @channel.unsubscribe()
    @queue.dispose()
    User.addMe()
    @pairingSetup()

  createSharePane: (editor, id, title) ->
    new SharePane({
      editor: editor,
      pusher: @pusher,
      sessionId: @id,
      queue: @queue,
      id: id,
      title: title
    })

  ensureActiveTextEditor: (fn)->
    editor = atom.workspace.getActiveTextEditor()
    if !editor
      @engageTabListener = false
      atom.workspace.open().then (editor)->
        @engageTabListener = true
        fn(editor)
    else
      @engageTabListener = true
      fn(editor)

  shareOpenPanes: ->
    @ensureActiveTextEditor =>
      _.each atom.workspace.getTextEditors(), (editor) => @createSharePane(editor)

  setActive: ->
    @active = true
    @constructor.active = @

  startPairing: ->
    @setActive()

    @subscriptions.add atom.commands.add 'atom-workspace', 'AtomPair:disconnect': => @end()
    if User.me.isLeader() then @shareOpenPanes()
    @subscriptions.add @listenForNewTab()

    @channel.bind 'client-i-made-a-share-pane',(data) =>
      return unless data.to is User.me.colour or data.to is 'all'
      sharePane = SharePane.id(data.paneId)
      sharePane.shareFile()
      sharePane.sendGrammar()

    @channel.bind 'client-please-make-a-share-pane', (data) =>
      return unless data.to is User.me.colour or data.to is 'all'
      paneId = data.paneId
      title = data.title
      @engageTabListener = false
      atom.workspace.open().then (editor)=>
        pane = @createSharePane(editor, paneId, title)
        @queue.add(@channel.name, 'client-i-made-a-share-pane', {to: data.from, paneId: paneId})
        @engageTabListener = true

    @channel.bind 'pusher:member_added', (member) =>
      atom.notifications.addSuccess "Your pair buddy has joined the session."
      User.add(member.id, member.arrivalTime)
      return unless User.me.isLeader()
      SharePane.each (sharePane) =>
        @queue.add(@channel.name, 'client-please-make-a-share-pane', {
          to: member.id,
          from: User.me.colour,
          paneId: sharePane.id,
          title: sharePane.editor.getTitle()
        })
        sharePane.addMarker(0, member.id)

    @channel.bind 'pusher:member_removed', (member) =>
      User.remove(member.id)
      SharePane.each (sharePane) -> sharePane.clearMarkers(member.id)
      atom.notifications.addWarning('Your pair buddy has left the session.')

    @listenForDestruction()

  listenForNewTab: ->
    atom.workspace.onDidOpen (e) =>
      return unless @engageTabListener
      editor = e.item
      return unless editor.constructor.name is "TextEditor"
      sharePane = @createSharePane(editor)
      @queue.add(@channel.name, 'client-please-make-a-share-pane', {
        to: 'all',
        from: User.me.colour,
        paneId: sharePane.id,
        title: editor.getTitle()
      })

  listenForDestruction: ->
    SharePane.globalEmitter.on 'disconnected', =>
      if (_.all SharePane.all, (pane) => !pane.connected) then @end()