# test.type = 'error'
# eval = 'typecheck'
# 
# [test.metadata]
# error = 'TypecheckError::TypeMismatch'
#
# [test.metadata.expectation]
# expected = 'Array _a'
# found = 'Number'
(let head = fun l => (%elem_at% l 0) in (head 10)) : _