utils = {}

utils.typeOf = (value) ->
  type = typeof value
  if type is 'object' or type is 'function'
    return 'null'  if value is null
    return 'array' if value instanceof Array

    type = switch value.constructor
      when String   then 'string'
      when Number   then 'number'
      when RegExp   then 'regexp'
      when Function then 'function'
      when Date     then 'date'
      else          type
  type

utils.merge = (target, objects...) ->
  deep = yes
  if typeof target is 'boolean'
    [deep, target] = [target, objects.shift()]

  if not objects.length
    [target, objects] = [this, [target]]

  isExtendable = (object) ->
    typeof object is 'object' and object isnt null or
    typeof object is 'function' or
    Array.isArray(object)

  target = {} unless isExtendable target

  for object in objects
    continue unless isExtendable object
    for key, copy of object
      continue unless Object::hasOwnProperty.call object, key

      if deep and isExtendable copy and target isnt copy
        src = target[key]
        if Array.isArray copy
          clone = Array.isArray(src) and src or []
          clone.push copy...
          copy = clone
        else
          copy = arguments.callee deep, src, copy
      target[key] = copy
  target

utils.reverse_merge = (objects...) ->
  return {} if not objects.length

  if typeof objects[0] is 'boolean'
    utils.merge objects.shift(), objects.reverse()...
  else
    utils.merge objects.reverse()...

module.exports = utils

