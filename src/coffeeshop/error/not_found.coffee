NotFound = (msg) ->
  @name = 'NotFound'
  Error.call @, msg
  Error.captureStackTrace @, arguments.callee
  @

NotFound::__proto__ = Error.prototype

module.exports = NotFound

