module Tables

using IteratorInterfaceExtensions

export rowtable, columntable

# helper functions
names(::Type{NamedTuple{nms, typs}}) where {nms, typs} = nms
types(::Type{NamedTuple{nms, typs}}) where {nms, typs} = Tuple(typs.parameters)

"Abstract row type with a simple required interface: row values are accessible via `getproperty(row, field)`; for example, a NamedTuple like `nt = (a=1, b=2, c=3)` can access it's value for `a` like `nt.a` which turns into a call to the function `getproperty(nt, :a)`"
abstract type Row end

"""
    The Tables.jl package provides three useful interface functions for working with tabular data in a variety of formats.

    `Tables.schema(table) => NamedTuple{names, types}`
    `Tables.rows(table) => Row-iterator`
    `Tables.columns(table) => NamedTuple of AbstractVectors`

Essentially, for any table type that implements the interface requirements, one can get access to:
    1) the schema of a table, returned as a NamedTuple _type_, with parameters of `names` which are the column names, and `types` which is a `Tuple{...}` type of types
    2) rows of the table via a Row-iterator
    3) the columns of the table via a NamedTuple of AbstractVectors, where the NamedTuple keys are the column names.

So how does one go about satisfying the Tables.Table interface? We must ensure the three methods get satisfied for a given table type.

    `Tables.schema`: given an _instance_ of a table type, generate a `NamedTuple` type, with a tuple of symbols for column names (e.g. `(:a, :b, :c)`), and a tuple type of types as the 2nd parameter (e.g. `Tuple{Int, Float64, String}`); like `NamedTuple{(:a, :b, :c), Tuple{Int, Float64, String}}`

    `Tables.rows`:
        - overload `Tables.rows` directly for your table type (e.g. `Tables.rows(t::MyTableType)`), and return an iterator of `Row`s. Where a `Row` type is any object with keys accessible via `getproperty(obj, key)`
        - define `Tables.producescells(::Type{<:MyTableType}) = true`, as well as `Tables.getcell(t::MyTableType, ::Type{T}, row::Int, col::Int)` and `Tables.isdonefunction(::Type{<:MyTableType})::Function`; a generic `Tables.rows(x)` implementation will use these definitions to generate a valid `Row` iterator for `MyTableType`

    `Tables.columns`:
        - overload `Tables.columns` directly for your table type (e.g. `Tables.columns(t::MyTableType)`), returning a NamedTuple of AbstractVectors, with keys being the column names
        - define `Tables.producescolumns(::Type{<:MyTableType}) = true`, as well as `Tables.getcolumn(t::MyTableType, ::Type{T}, col::Int)`; a generic `Tables.columns(x)` implementation will use these definitions to generate a valid NamedTuple of AbstractVectors for `MyTableType`
        - define `Tables.producescells(::Type{<:MyTableType}) = true`, as well as `Tables.getcell(t::MyTableType, ::Type{T}, row::Int, col::Int)` and `Tables.isdonefunction(::Type{<:MyTableType})::Function`; again, the generic `Tables.columns(x)` implementation can use these definitions to generate a valid NamedTuple of AbstractVectors for `MyTableType`

The final question is how `MyTableType` can be a "sink" for any other table type:

    - Define a function or constructor that takes, at a minimum, a single, untyped argument and then calls `Tables.rows` or `Tables.columns` on that argument to construct an instance of `MyTableType`

For example, if `MyTableType` is a row-oriented format, I might define my "sink" function like:
```julia
function MyTableType(x)
    mytbl = MyTableType(Tables.schema(x))
    for row in Tables.rows(x)
        append!(mytbl, row)
    end
    return mytbl
end
```
Alternatively, if `MyTableType` is column-oriented, perhaps my definition would be more like:
```
function MyTableType(x)
    cols = Tables.columns(x)
    return MyTableType(collect(map(String, keys(cols))), [col for col in cols])
end
```
Obviously every table type is different, but via a combination of `Tables.schema`, `Tables.rows`, and `Tables.columns`, each table type should be able to construct an instance of itself.
"""
abstract type Table end

"Tables.schema(s) => NamedTuple{names, types}"
function schema end

"`Tables.producescells(::Type{<:MyTable}) = true` to signal your table type can produce individual cells"
function producescells end
producescells(x) = false

"`Tables.getcell(source, ::Type{T}, row, col)::T` gets an individual cell value from source"
function getcell end

"`Tables.isdonefunction(::Type{<:MyTable})::Function` returns a function which, when called on an instance of `MyTable`, returns a `Bool` indicating if the table is done iterating rows yet or not"
function isdonefunction end

"`Tables.producescolumns(::Type{<:MyTable}) = true` to signal your table type can produce individual columns"
function producescolumns end
producescolumns(x) = false

"`Tables.getcolumn(source, ::Type{T}, col::Int)` gets an individual column from source"
function getcolumn end

# Row iteration
struct RowIterator{S, F, NT}
    source::S
    f::F
end

Base.eltype(rows::RowIterator{S, F, NT}) where {S, F, NT} = NT
Base.IteratorSize(::Type{<:RowIterator}) = Base.SizeUnknown()

"Returns a NamedTuple-iterator"
function RowIterator(source::S, f::F) where {S, F}
    sch = schema(source)
    return RowIterator{S, F, NamedTuple{names(sch), Tuple{types(sch)...}}}(source, f)
end

function Base.iterate(rows::RowIterator{S, F, NamedTuple{names, types}}, st=1) where {S, F, names, types}
    if @generated
        vals = Tuple(:(Tables.getcell(rows.source, $typ, st, $col)) for (col, typ) in enumerate(types.parameters) )
        q = quote
            rows.f(rows.source, st) && return nothing
            return ($(NamedTuple{names, types}))(($(vals...),)), st + 1
        end
    else
        rows.f(rows.source, st) && return nothing
        return NamedTuple{names, types}(Tuple(Tables.getcell(rows.source, T, st, col) for (col, T) in enumerate(types.parameters))), st + 1
    end
end

function rows(x::T) where {T}
    if producescells(T)
        return RowIterator(x, Tables.isdonefunction(T))
    else
        # throw(ArgumentError("Type $T doesn't seem to support the `Tables.rows` interface; it should overload `Tables.rows(x::$T)` directly or define `Tables.producescells(::Type{$T}) = true` and `Tables.getcell(t::$T, ::Type{T}, row::Int, col::Int)::T`"))
        return x # assume x implicitly satisfies interface by iterating Rows
    end
end

function buildcolumns(rows::RowIterator{S, F, NamedTuple{names, types}}) where {S, F, names, types}
    if @generated
        vals = Tuple(:(Vector{$typ}(undef, 0)) for typ in types.parameters)
        innerloop = Expr(:block)
        for nm in names
            push!(innerloop.args, :(push!(nt[$(Meta.QuoteNode(nm))], getproperty(row, $(Meta.QuoteNode(nm))))))
        end
        q = quote
            nt = NamedTuple{names}(($(vals...),))
            for row in rows
                $innerloop
            end
            return nt
        end
        # @show q
        return q
    else
        nt = NamedTuple{names}(Tuple(Vector{typ}(undef, 0) for typ in T.parameters))
        for row in rows
            for key in keys(nt)
                push!(nt[key], getproperty(row, key))
            end
        end
        return nt
    end
end

function columns(x::T) where {T}
    if producescolumns(T)
        sch = Tables.schema(x)
        return NamedTuple{names(sch)}(Tuple(Tables.getcolumn(x, T, i) for (i, T) in enumerate(types(sch))))
    elseif producescells(T)
        return buildcolumns(RowIterator(x, Tables.isdonefunction(T)))
    else
        return x # assume x implicitly satisfies interface by return a NamedTuple of AbstractVectors
    end
end

include("namedtuples.jl")

# IteratorInterfaceExtensions.getiterator(x::Table) = rows(x)

end # module

#TODO
 # test various code paths
 # getiterator
 # datavalues iterator