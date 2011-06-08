class BaseController
  request:  null
  response: null
  locals:   {}

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

  render: (name, options) ->
    name ||= @request.params.action.underscored()
    name = "#{@toString()}/#{name}" unless '/' in name

    options ||= {}
    options.locals ||= {}
    options.locals = Object.merge {}, @locals, options.locals

    @response.render name, options

  send: -> @response.send arguments...

  before_filter: -> true
  after_filter:  ->

module.exports = BaseController

