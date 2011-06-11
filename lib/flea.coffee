#
# Load required dependencies
#

Express   = require 'express'
Mongoose  = require 'mongoose'
Haml      = require 'haml'
Stylus    = require 'stylus'
File      = require 'fs'
Path      = require 'path'
RightJS   = require 'rightjs'

# Load additional Mongoose types

MongooseTypes = require 'mongoose-types'
MongooseTypes.loadTypes Mongoose

#
# Resolve project and application directory paths
#

__packagedir = Path.resolve __dirname, '..'
__projectdir = process.cwd()
__appdir = __projectdir + '/app'

require.paths.unshift __packagedir
require.paths.unshift __packagedir + '/lib'

#
# Load our internal stuff
#

Utils = require 'utils'

Object.defineProperty Object, 'type',
  value: Utils.typeOf

Object.defineProperty Object, 'merge',
  value: Utils.merge

Object.defineProperty Object, 'reverse_merge',
  value: Utils.reverse_merge

#
# Miscellaneous helper functions
#

puts = console.log

#
# Monkey patching Mongoose to support model dependencies
#

loaded_models    = []
dependant_models = []

Mongoose.schema = (name) ->
  schema = @modelSchemas[name]
  if not schema?
    throw new Error "No schema registered for '#{name}'"
  schema

Mongoose.old_model = Mongoose.model
Mongoose.model = (name, schema) ->
  model = @old_model arguments...

  if schema instanceof @Schema
    already_loaded = loaded_models.reject (model) -> model is name

    for dependant in dependant_models
      if (name in dependant.on) and not (name in dependant.satisfied)
        dependant.satisfied.push name

      for loaded_one in already_loaded
        if (loaded_one in dependant.on) and not (loaded_one in dependant.satisfied)
          dependant.satisfied.push loaded_one

      if dependant.satisfied.length is dependant.on.length and not dependant.loaded
        dependant.loaded = yes
        dependant.callback()

    loaded_models.push name unless name in loaded_models

  model

#
# Our shit
#

NotFound = require 'error/not_found'

BaseController        = require 'base_controller'
ApplicationController = null
do ->
  for path in [__appdir + '/controllers', __packagedir + '/lib']
    path += '/application_controller.coffee'

    continue unless Path.existsSync path
    sandbox =
      BaseController: BaseController
      NotFound: NotFound

      Mongoose: Mongoose
      ObjectId: Mongoose.Schema.Types.ObjectId

    Utils.runFileInNewContext path, sandbox
    ApplicationController = sandbox['ApplicationController']


#
# Main class
#

class Flea
  constructor: ->
    @controllers = {}
    @routes = []
    @config =
      session:
        secret: 'squirrel-octo-cat in the sudden co-attack.!'
        key: 'sid'

      stylus:
        src:  __appdir + '/views'
        dest: __projectdir + '/public'
        #compress: yes
        debug: yes

    @load_config()
    @load_models()

    @setup_app()
    @setup_errorhandlers()

    #require 'express-namespace'
    @router_methods = ['del'].merge Express.router.methods

    @load_routes()
    @load_controllers()

    @app.all '*', -> throw new NotFound

  #
  # @api: private
  #
  register_route: (src, options) ->
    route = {}
    route.method = ['all']

    if options.as? and typeof options.as is 'string'
      route.alias = options.as

    if via = options.via
      via = [via] if typeof via is 'string'
      if Array.isArray via
        via = RightJS.$A via # needed 'cause Array objects returned from sandbox are of different parent
        via = via.filter (verb) => verb in @router_methods
        via = via.uniq()
        route.method = via unless via.empty()

    unless Object.type(src) in ['string', 'function', 'regexp']
      throw new Error 'You must provide string, regexp or function as route src'

    if typeof src is 'string'
      unless options.to?
        options.to = src.replace /\//g, '#'
        options.to = options.to.replace /^#+/, ''

      src = '/' + src if src[0] isnt '/'

    route.src = src

    unless Object.type(options.to) in ['string', 'function']
      throw new Error 'You must provide valid route destination'

    if typeof options.to is 'string'
      [route.controller, route.action] = options.to.split '#'
      unless route.controller?
        throw new Error 'You must provide valid route controller'

      route.action ||= 'index'
    else
      route.fn = options.to

    if Object.type(options.constraints) is 'object'
      route.constraints = options.constraints

      for param, constraint of route.constraints
        unless Object.type(constraint) in ['array', 'regexp']
          delete route.constraints[param]
          continue

        continue if Object.type(constraint) is 'array'

        src = constraint.source
        flags = if constraint.ignoreCase then 'i' else ''

        if src[0] isnt '^'
          src = '^' + src
        if src[src.length - 1] isnt '$'
          src = src + '$'

        unless constraint.source is src
          route.constraints[param] = new RegExp src, flags

    if Object.type(options.defaults) is 'object'
      route.defaults = options.defaults

    @routes.push route
    #puts route

    for method in route.method
      if typeof route.src is 'function'
        @app[method] '*', (req, res, next) =>
          if route.src req
            @dispatch route, arguments...
          else
            next()
      else
        @app[method] route.src, (req, res, next) =>
          @dispatch route, arguments...

  #
  # @api: private
  #
  dispatch: (route, req, res, next) ->
    if route.defaults?
      for param, value of route.defaults
        req.params[param] = value if req.params[param] is undefined

    if route.constraints?
      for param, constraint of route.constraints
        if Object.type(constraint) is 'array'
          return next() unless req.params[param] in constraint
        else
          return next() unless constraint.test req.params[param]

    if route.fn?
      return route.fn req, res, next

    controller_name = "#{route.controller}_controller".capitalize().camelize()
    if not controller = @controllers[controller_name]
      return next new Error "#{controller_name} not found!"

    req.params.action ||= route.action
    req.params.action = req.params.action.camelize()

    controller = new controller req, res
    controller.template_root = route.controller

    if controller.before_filter()?
      action = req.params.action
      unless typeof controller[action] is 'function'
        next new Error "#{route.controller}##{action} is not a controller action!"
      else
        controller[action] req, res, next
        controller.render() if controller.auto_render

      controller.after_filter()

    delete controller

  #
  # @api: private
  #
  load_config: ->
    sandbox = {}
    Utils.runFileInNewContext __projectdir + '/config/config.coffee', sandbox
    Object.merge @config, sandbox.config

  #
  # @api: private
  #
  load_models: ->
    models = File.readdirSync __appdir + '/models'
    models = models.filter (filename) -> filename.match /\.(coffee|js)$/
    for name in models
      @load_model name

  #
  # @api: private
  #
  load_model: (name) ->
    sandbox =
      Mongoose: Mongoose
      ObjectId: Mongoose.Schema.Types.ObjectId

      useTimestamps: MongooseTypes.useTimestamps

      depends_on: (models, callback) ->
        models = [models] if not Array.isArray models
        dependant =
          on: RightJS.$A models
          satisfied: []
          callback: callback
          loaded: no
        dependant_models.push dependant

    Utils.runFileInNewContext __appdir + '/models/' + name, sandbox

    name = name.replace /\.(.+)$/, ''
    name = name.capitalize().camelize()

    if schema = sandbox[name]
      Mongoose.model name, schema
    else
      console.warn 'Did not find model definition for "%s".', name

  #
  # @api: private
  #
  load_controllers: ->
    controllers = File.readdirSync __appdir + '/controllers'
    controllers = controllers.filter (filename) -> filename.match /\.(coffee|js)$/
    for name in controllers
      @load_controller name

  #
  # @api: private
  #
  load_controller: (name) ->
    sandbox =
      BaseController: BaseController
      ApplicationController: ApplicationController
      NotFound: NotFound

      Mongoose: Mongoose
      ObjectId: Mongoose.Schema.Types.ObjectId

    Utils.runFileInNewContext __appdir + '/controllers/' + name, sandbox

    name = name.replace /\.(.+)$/, ''
    name = name.capitalize().camelize()

    if controller = sandbox[name]
      @controllers[name] = controller
    else
      console.warn 'Did not find controller definition for "%s".', name

  #
  # @api: private
  #
  load_routes: ->
    sandbox =
      app: @app

      scope: => @app.namespace arguments...
      param: => @app.param arguments...

      root: (options) =>
        @register_route '/', Object.reverse_merge options, as: 'root'

      match: (src, options) =>
        @register_route arguments...

    for method in @router_methods
      do (method) =>
        sandbox[method] = (src, options) ->
          sandbox.match src, Object.merge {}, options, via: method

    Utils.runFileInNewContext __projectdir + '/config/routes.coffee', sandbox

  #
  # @api: private
  #
  setup_app: ->
    @app = Express.createServer()

    @app.configure 'development', =>
      @app.use Express.logger '\x1b[33m:method\x1b[0m \x1b[32m:url \x1b[1;30m:status\x1b[0m :response-timems'

    @app.configure =>
      @app.set 'views', __appdir + '/views'
      @app.set 'view engine', 'haml'

      @app.use Stylus.middleware @config.stylus
      @app.use Express.methodOverride()
      @app.use Express.bodyParser()
      @app.use Express.cookieParser()
      @app.use Express.session @config.session
      @app.use Express.static __projectdir + '/public'

    @app.configure 'development', =>
      @app.use Express.errorHandler dumpExceptions: yes, showStack: yes

    @app.configure 'production', =>
      @app.use Express.errorHandler()

    @app.register '.haml',
      compile: (str, options) ->
        template = Haml str
        (locals) -> template locals

    @app.dynamicHelpers
      messages: require 'express-messages'

  #
  # @api: private
  #
  setup_errorhandlers: ->
    @app.error (err, req, res, next) ->
      if err instanceof NotFound
        res.render '404', error: err
      else
        next err

    @app.error (err, req, res) ->
      res.render '500', error: err

  #
  # @api: public
  #
  start: (options) ->
    options = Object.reverse_merge options,
      port: 3000

    Mongoose.connect @config.mongodb.uri

    if options.hostname
      @app.listen options.port, options.hostname
    else
      @app.listen options.port

    puts ''
    puts 'Application listening on %s:%d', options.hostname || '*', options.port
    puts ''

#
# Export ze stuff
#

module.exports = new Flea

