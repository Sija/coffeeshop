#
# Load required dependencies
#

Express   = require 'express'
Mongoose  = require 'mongoose'
Haml      = require 'haml'
Stylus    = require 'stylus'
File      = require 'fs'
Path      = require 'path'
VM        = require 'vm'
RightJS   = require 'rightjs'

# Load additional Mongoose types

MongooseTypes = require 'mongoose-types'
MongooseTypes.loadTypes Mongoose

#
# Resolve project and application directory paths
#

__packagedir = Path.resolve __dirname, '..'
__projectdir = Path.dirname require.main.filename
__appdir = __projectdir + '/app'

require.paths.unshift __packagedir
require.paths.unshift __packagedir + '/lib'
require.paths.unshift __projectdir

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


loadAndRunInNewContext = (filename, sandbox) ->
  code = File.readFileSync filename, 'utf8'
  sandbox = Object.merge sandbox,
    require: require
    console: console

  VM.runInNewContext code, sandbox, filename

#
# Load config values
#

Config = {}
do ->
  sandbox = {}
  loadAndRunInNewContext __projectdir + '/config/config.js', sandbox
  Object.merge Config, sandbox.config

#
# Connect to local database
#

Mongoose.connect Config.mongodb.uri

#
# Load models
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

do ->
  models = File.readdirSync __appdir + '/models'
  models = models.filter (filename) -> filename.match /\.js$/
  for model in models
    do (model) ->
      sandbox =
        Mongoose: Mongoose
        ObjectId: Mongoose.Schema.Types.ObjectId

        depends_on: (models, callback) ->
          models = [models] if not Array.isArray models
          dependant =
            on: RightJS.$A models
            satisfied: []
            callback: callback
            loaded: no
          dependant_models.push dependant

      loadAndRunInNewContext __appdir + '/models/' + model, sandbox

      schema_name = model.replace /\.js$/, ''
      schema_name = schema_name.camelize().capitalize()

      if schema = sandbox[schema_name]
        Mongoose.model schema_name, schema
      else
        console.warn 'Did not find model definition for "%s".', schema_name

#
# Setup express application
#

app = Express.createServer()

app.configure 'development', ->
  app.use Express.logger '\x1b[33m:method\x1b[0m \x1b[32m:url \x1b[1;30m:status\x1b[0m :response-timems'

app.configure ->
  app.set 'views', __appdir + '/views'
  app.set 'view engine', 'haml'

  app.use Stylus.middleware Object.reverse_merge Config.stylus,
    src:  __appdir + '/views'
    dest: __projectdir + '/public'
    #compress: yes
    debug: yes

  app.use Express.methodOverride()
  app.use Express.bodyParser()
  app.use Express.cookieParser()
  app.use Express.session Object.reverse_merge Config.session,
    secret: 'squirrel-octo-cat in the sudden co-attack.!'
    key: 'sid'
  app.use Express.static __projectdir + '/public'

app.configure 'development', ->
  app.use Express.errorHandler dumpExceptions: yes, showStack: yes

app.configure 'production', ->
  app.use Express.errorHandler()

app.register '.haml',
  compile: (str, options) ->
    template = Haml str
    (locals) -> template locals

app.dynamicHelpers
  messages: require 'express-messages'

#
# Setup our custom neat-o error handlers
#

NotFound = require 'error/not_found'

app.error (err, req, res, next) ->
  if err instanceof NotFound
    res.render '404', error: err
  else
    next err

app.error (err, req, res) ->
  res.render '500', error: err

#
# Load custom routes
#

#require 'express-namespace'

BaseController = require 'base_controller'
ApplicationController = null
do ->
  for path in [__appdir + '/controllers', __packagedir + '/lib']
    path += '/application_controller.js'

    continue unless Path.existsSync path
    sandbox =
      BaseController: BaseController

      Mongoose: Mongoose
      ObjectId: Mongoose.Schema.Types.ObjectId

    loadAndRunInNewContext path, sandbox
    ApplicationController = sandbox['ApplicationController']

router_dsl =
  router:
    methods: ['del'].merge Express.router.methods

  scope: -> app.namespace arguments...
  param: -> app.param arguments...

  root: (options) ->
    router_dsl.match '/', Object.reverse_merge options, as: 'root'

  match: (src, options) ->
    route =
      alias: typeof options.as is 'string' and options.as or null
      method: ['all']

    if via = options.via
      via = [via] if typeof via is 'string'
      if Array.isArray via
        via = RightJS.$A via.filter (verb) -> router_dsl.router.methods.includes verb
        via = via.uniq()
        route.method = via unless via.empty()

    unless ['string', 'function'].includes(typeof src) or src instanceof Regex
      throw new Error 'You must provide string, regex or function as route src'

    if typeof src is 'string'
      src = '/' + src if src[0] isnt '/'

      options.to ||= src.replace /\//g, '#'
      options.to = options.to.replace /^#+/, ''

    unless ['string', 'function'].includes typeof options.to
      throw new Error 'You must provide valid route destination'

    [route.controller, route.action] = options.to.split '#'

    if not route.controller?
      throw new Error 'You must provide valid route controller'

    route.action ||= 'index'
    route.src = src

    #console.log route

    for method in route.method
      do (method) ->
        app[method].call app, route.src, (req, res, next) ->
          sandbox =
            BaseController: BaseController
            ApplicationController: ApplicationController

            Mongoose: Mongoose
            ObjectId: Mongoose.Schema.Types.ObjectId

          loadAndRunInNewContext "#{__appdir}/controllers/#{route.controller}_controller.js", sandbox

          ctrl_name = "#{route.controller.capitalize()}_controller".camelize()
          if not ctrl = sandbox[ctrl_name]
            next new Error "#{route.controller.capitalize()} controller not defined!"
            return

          req.params.action ||= 'index'
          req.params.action = req.params.action.camelize()

          ctrl = new ctrl req, res
          ctrl.toString = -> route.controller

          if ctrl.before_filter()?
            cb = req.params.action + 'Action'
            unless typeof ctrl[cb] is 'function'
              next new Error req.params.action + ' is not a controller action!'
            else
              ctrl[cb].call ctrl, req, res, next
            ctrl.after_filter()

          delete ctrl

    @

do ->
  for method in router_dsl.router.methods
    do (method) ->
      router_dsl[method] = (src, options = {}) ->
        router_dsl.match src, Object.merge {}, options, via: method

do ->
  sandbox = Object.reverse_merge router_dsl,
    app: app

  loadAndRunInNewContext __projectdir + '/config/routes.js', sandbox

#
# Load controllers and register default routes
#

do ->
  controllers = File.readdirSync __appdir + '/controllers'
  controllers = controllers.filter (filename) -> filename.match /\.js$/
  for name in controllers
    do (name) ->
      name = name.underscored().replace /_controller\.js$/, ''
      router_dsl.match "/#{name}/:action?/:id?.:format?", to: name
#
# Register fallback route
#

app.all '*', -> throw new NotFound

#
# Run the application
#

app.listen 3000

