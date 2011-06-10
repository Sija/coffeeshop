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
      if dependant.on.includes(name) and not dependant.satisfied.includes(name)
        dependant.satisfied.push name

      for loaded_one in already_loaded
        if dependant.on.includes(loaded_one) and not dependant.satisfied.includes(loaded_one)
          dependant.satisfied.push loaded_one

      if dependant.satisfied.length is dependant.on.length and not dependant.loaded
        dependant.loaded = yes
        dependant.callback()

    loaded_models.push name unless loaded_models.includes name

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
  controllers: {}
  config:
    session:
      secret: 'squirrel-octo-cat in the sudden co-attack.!'
      key: 'sid'

    stylus:
      src:  __appdir + '/views'
      dest: __projectdir + '/public'
      #compress: yes
      debug: yes

  constructor: ->
    @load_config()
    @load_models()

    @setup_app()
    @setup_errorhandlers()

    #require 'express-namespace'
    @router_dsl =
      router:
        methods: ['del'].merge Express.router.methods

      scope: => @app.namespace arguments...
      param: => @app.param arguments...

      root: (options) =>
        @router_dsl.match '/', Object.reverse_merge options, as: 'root'

      match: (src, options) =>
        route =
          alias: typeof options.as is 'string' and options.as or null
          method: ['all']

        if via = options.via
          via = [via] if typeof via is 'string'
          if Array.isArray via
            via = RightJS.$A via.filter (verb) => @router_dsl.router.methods.includes verb
            via = via.uniq()
            route.method = via unless via.empty()

        unless Object.type(src) in ['string', 'function', 'regexp']
          throw new Error 'You must provide string, regexp or function as route src'

        if typeof src is 'string'
          src = '/' + src if src[0] isnt '/'

          options.to ||= src.replace /\//g, '#'
          options.to = options.to.replace /^#+/, ''

        unless Object.type(options.to) in ['string', 'function']
          throw new Error 'You must provide valid route destination'

        [route.controller, route.action] = options.to.split '#'

        if not route.controller?
          throw new Error 'You must provide valid route controller'

        route.action ||= 'index'
        route.src = src

        #puts route

        for method in route.method
          do (method) =>
            @app[method].call @app, route.src, (req, res, next) =>

              ctrl_name = "#{route.controller}_controller".capitalize().camelize()
              if not ctrl = @controllers[ctrl_name]
                next new Error "#{ctrl_name} not found!"
                return

              req.params.action ||= route.action
              req.params.action = req.params.action.camelize()

              ctrl = new ctrl req, res
              ctrl.toString = -> route.controller

              if ctrl.before_filter()?
                action = req.params.action
                unless typeof ctrl[action] is 'function'
                  next new Error "#{route.controller}##{action} is not a controller action!"
                else
                  ctrl[action](req, res, next)
                  ctrl.render() if ctrl.auto_render

                ctrl.after_filter()

              delete ctrl

        @


    @load_routes()
    @load_controllers()

    @app.all '*', -> throw new NotFound

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

    schema_name = name.replace /\.(.+)$/, ''
    schema_name = schema_name.capitalize().camelize()

    if schema = sandbox[schema_name]
      Mongoose.model schema_name, schema
    else
      console.warn 'Did not find model definition for "%s".', schema_name

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

    ctrl_name = name.replace /\.(.+)$/, ''
    ctrl_name = ctrl_name.capitalize().camelize()

    if ctrl = sandbox[ctrl_name]
      @controllers[ctrl_name] = ctrl
    else
      console.warn 'Did not find controller definition for "%s".', ctrl_name

  #
  # @api: private
  #
  load_routes: ->
    for method in @router_dsl.router.methods
      do (method) =>
        @router_dsl[method] = (src, options = {}) =>
          @router_dsl.match src, Object.merge {}, options, via: method

    sandbox = Object.reverse_merge @router_dsl, app: @app
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

