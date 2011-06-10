class BaseController
  request:      null
  response:     null
  locals:       {}
  auto_render:  yes

  constructor: (@request, @response) ->

  local: (key, value) ->
    if typeof key is 'object'
      @locals[k] = v for k, v of key
      @locals
    else
      @locals[key] = value if value
      @locals[key]

  param: (name, def) ->
    @request.param name, def

  render: (template, options) ->
    [template, options] = [null, template] unless typeof template is 'string'

    template ||= @request.params.action.underscored()
    template = "#{@toString()}/#{template}" unless '/' in template

    options ||= {}
    options.locals ||= {}
    options.locals = Object.merge {}, @locals, options.locals

    @auto_render = no
    @response.render template, options

  send: ->
    @auto_render = no
    @response.send arguments...

  redirect: ->
    @auto_render = no
    @response.redirect arguments...

  before_filter: -> true
  after_filter: ->

module.exports = BaseController

