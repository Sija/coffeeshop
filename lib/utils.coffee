File    = require 'fs'
VM      = require 'vm'
Coffee  = require 'coffee-script'

#
# @api: public
#
utils = {}

#
# @api: public
#
utils.typeOf = (value) ->
  type = typeof value
  if type in ['object', 'function']
    return 'null'  if value is null
    return 'array' if Array.isArray value

    type = Object::toString.call(value)
      .match(/\[object (.+)\]/)[1]
      .toLowerCase()
  type

#
# @api: public
#
utils.merge = (target, objects...) ->
  deep = yes
  if typeof target is 'boolean'
    [deep, target] = [target, objects.shift()]

  if not objects.length
    [target, objects] = [this, [target]]

  isExtendable = (object) ->
    !!object and typeof object is 'object' and not Array.isArray object

  target = {} unless isExtendable target

  for object in objects
    continue unless isExtendable object
    for key, copy of object
      continue unless Object::hasOwnProperty.call object, key

      if deep and target isnt copy and isExtendable copy
        if src = target[key]
          copy = arguments.callee deep, {}, src, copy
      target[key] = copy
  target

#
# @api: public
#
utils.reverse_merge = (objects...) ->
  return {} if not objects.length

  if typeof objects[0] is 'boolean'
    utils.merge objects.shift(), objects.reverse()...
  else
    utils.merge objects.reverse()...

#
# @api: public
#
utils.runFileInNewContext = (filename, sandbox) ->
  run = (filename, sandbox) ->
    code = File.readFileSync filename, 'utf8'
    if filename.match /\.coffee$/
      code = Coffee.compile code,
        filename: filename
        bare: yes

    sandbox = utils.merge sandbox,
      require: require
      console: console

    VM.runInNewContext code, sandbox, filename

  try
    run filename, sandbox

  catch error
    throw error unless error.code is 'EBADF'

    if filename.match /\.coffee$/
      filename = filename.replace /\.coffee$/, '.js'
    else
      filename = filename.replace /\.js$/, '.coffee'

    run filename, sandbox

module.exports = utils

