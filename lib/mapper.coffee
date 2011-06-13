
#
#
#

Express = require 'express'

#
#
#

class Mapping

  #
  # @api: public
  #
  constructor: (@path, @options, @allowed_methods) ->
    @normalize_path()
    @normalize_options()

  #
  # @api: public
  #
  to_route: ->
    route =
      path:         @path
      method:       @options.via          || ['all']
      alias:        @options.as           || null
      constraints:  @options.constraints  || null
      defaults:     @options.defaults     || null
      controller:   @options.controller   || null
      action:       @options.action       || null
      callback:     @options.callback     || null

    for key, value of route
      delete route[key] unless value?
    route

  #
  # @api: private
  #
  normalize_path: ->
    unless Object.type(@path) in ['string', 'function', 'regexp']
      throw new Error "Route path must be either a string, regexp or function, #{Object.type @path} given"

    if typeof @path is 'string'
      @path = '/' + @path unless @path.startsWith '/'
      if @path isnt '/' and @path.endsWith '/'
        @path = @path.substr 0, @path.length - 1

  #
  # @api: private
  #
  normalize_options: ->
    if typeof @path is 'string'
      path_without_format = @path.replace /\.:format\??$/, ''

      if @using_match_shorthand path_without_format, @options
        @options.to ||= @path.substr(1).replace /\//g, '#'

    if Object.type(@options.to) in ['string', 'function']
      if typeof @options.to is 'string'
        [@options.controller, @options.action] = @options.to.split '#'
      else
        @options.callback = @options.to

    else if @options.to?
      throw new Error "destination must be a string or function, #{Object.type @options.to} given"

    unless @options.controller? || @options.callback
      throw new Error "controller missing"

    unless @options.callback
      @options.action ||= 'index'
      ###
      unless @options.action?
        throw new Error "action missing"
      ###

    if @options.as? and typeof @options.as isnt 'string'
      throw new Error "alias must be a string, #{Object.type @options.as} given"

    if Object.type(@options.via) in ['array', 'string']
      @options.via = [@options.via] if typeof @options.via is 'string'
      for method in @options.via
        throw new Error "unrecognized method #{method} given" unless method in @allowed_methods

    else if @options.via?
      throw new Error "method must be a string or an array, #{Object.type @options.via} given"

    if Object.type(@options.constraints) is 'object'
      for param, constraint of @options.constraints
        continue if Array.isArray constraint

        unless Object.type(constraint) is 'regexp'
          throw new Error "constraint for param #{param} must be a regexp or array, #{Object.type constraint} given"

        if constraint.multiline
          throw new Error "Regexp multiline option not allowed in routing constraint #{constraint} for param #{param}"

        src = constraint.source
        src = '^' + src unless src.startsWith '^'
        src = src + '$' unless src.endsWith '$'

        unless constraint.source is src
          flags = constraint.toString().match(/\/([a-z]+)?$/)[1]
          @options.constraints[param] = new RegExp src, flags

    else if @options.constraints?
      throw new Error "constraints must be an object, #{Object.type @options.constraints} given"

    if Object.type(@options.defaults) is 'object'
      for param, value of @options.defaults
        unless typeof value is 'string'
          throw new Error "default value for routing param #{param} must be a string, #{Object.type value} given"

    else if @options.defaults?
      throw new Error "defaults must be an object, #{Object.type options.defaults} given"

  #
  # @api: private
  #
  using_match_shorthand: (path, options) ->
    # Object.empty(Object.without(options, 'via', 'to', 'as'))
    not options.controller? and not options.action? and path.match /^\/[\w\/]+$/

#
#
#

class Mapper

  #
  # @api: public
  #
  constructor: ->
    @router_methods = ['del'].merge Express.router.methods
    @routes = []

    for method in @router_methods
      do (method) =>
        this[method] = (path, options) ->
          @match path, Object.merge {}, options, via: method

  #
  # @api: public
  #
  root: (options) ->
    @match '/', Object.reverse_merge options, as: 'root'

  #
  # @api: public
  #
  match: (path, options) ->
    try
      mapping = new Mapping path, options, @router_methods
      route = mapping.to_route()
    catch error
      error.message = "Route '#{path}' error: #{error.message}"
      throw error

    @routes.push route
    #puts route

  #
  # @api: public
  #
  scope: (path, options, callback) ->
    if typeof path isnt 'string'
      [path, options, callback] = ['', path, options]

    if Object.type(options) is 'function'
      [options, callback] = [{}, options]

    path = path + '/' unless path.endsWith '/'

    match = @match.bind this
    try
      @match = (scoped_path, scoped_options) =>
        unless typeof scoped_path is 'string'
          [scoped_path, scoped_options] = ['', scoped_path]

        scoped_path = scoped_path.substr(1) if scoped_path.startsWith '/'
        match path + scoped_path, Object.merge {}, options, scoped_options

      callback()
    finally
      @match = match

module.exports = Mapper

