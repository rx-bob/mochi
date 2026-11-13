# Supported Ruby surface

Mochi implements a practical Ruby interface for browser applications. This
document records supported forms and explicit VM limits. It does not promise
full MRI, Enumerable, or arbitrary-precision compatibility.

## Numeric rounding

`Integer` and binary64 `Float` support these ordinary methods:

| Method | Supported call | Return type |
| --- | --- | --- |
| `round` | `number.round` | Integer |
| `round` | `number.round(ndigits)` | Integer for Integer receivers or `ndigits <= 0`; Float for Float receivers and `ndigits > 0` |
| `round` | `number.round(ndigits, half: mode)` or `number.round(half: mode)` | Same as `round` above |
| `floor`, `ceil` | `number.floor`, `number.ceil` | Integer |
| `floor`, `ceil` | `number.floor(ndigits)`, `number.ceil(ndigits)` | Integer for `ndigits <= 0`; Float for positive precision on Float receivers; Integer receivers remain Integer |

`ndigits` must be an Integer in the inclusive range `-18..18`. Integer
receivers with nonnegative precision return unchanged. Negative precision
rounds to a power-of-ten multiple. Negative values use mathematical floor and
ceiling, and `round` defaults to nearest with exact halves away from zero.

The supported `half:` values are `:up` (nearest, ties away from zero), `:down`
(nearest, ties toward zero), and `:even` (nearest, ties to an even result).
Unknown options or modes produce an `invalid argument` error. Wrong arity,
nonnumeric receivers, and non-Integer precision produce source-located VM
errors. Precision outside the bound produces `invalid argument`.

Float calculations remain binary64 operations in the VM. Positive precision
preserves signed zero; positive-precision NaN and Infinity are returned
unchanged. At zero or negative precision, NaN or Infinity produces a
`non-finite float` error. A finite result outside the signed 64-bit Integer
range produces `integer overflow`. Integer results remain within the VM's
checked signed 64-bit range. These methods do
not provide decimal arithmetic or exact currency calculations; use
[`MochiMoney`](../README.md#money-helpers) for exact minor-unit accumulation.

Examples:

```ruby
(-1.5).round                 # -2
2.5.round(half: :even)        # 2
(-1.21).floor(1)              # -1.3
(-1.21).ceil(1)               # -1.2
12.floor(-1)                  # 10
```

Rounding is implemented as small VM numeric operations. It does not load the
number-formatting adapter or add a Ruby package dependency. The Float results
are binary64 and should not be used as exact-money values.

## Array aggregation

`Array#sum`, `Array#min`, and `Array#max` are loaded as optional Ruby bytecode
when a supported receiver call appears in a component or helper source. The
compiler tracks method-call syntax and helper dependencies; applications that
do not use these methods do not download the collection package.

- `sum` accepts an optional initial value and a block. A block transforms each
  element before addition. Numeric accumulation uses the VM's checked Integer
  and binary64 Float arithmetic; mixed numeric values promote to Float, and
  integer overflow is an error.
- `min` and `max` return `nil` for an empty array. Without a block, this version
  supports Integer, Float, and String ordering. With a block, the comparator
  receives the candidate and current value and must return a numeric ordering;
  `min` replaces the current value when the result is negative, while `max`
  replaces it when the result is positive.
- The size forms (`min(n)` and `max(n)`), enumerators, and nonnumeric `sum`
  operands are unsupported. Incomparable values and invalid comparator results
  produce source-located VM errors.

All forms use one pass and constant extra storage. The optional package adds no
host adapter and does not enter an app's initial package set unless its Ruby
call graph reaches one of these methods.
