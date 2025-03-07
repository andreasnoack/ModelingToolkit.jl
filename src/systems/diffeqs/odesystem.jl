"""
$(TYPEDEF)

A system of ordinary differential equations.

# Fields
$(FIELDS)

# Example

```julia
using ModelingToolkit

@parameters σ ρ β
@variables t x(t) y(t) z(t)
D = Differential(t)

eqs = [D(x) ~ σ*(y-x),
       D(y) ~ x*(ρ-z)-y,
       D(z) ~ x*y - β*z]

@named de = ODESystem(eqs,t,[x,y,z],[σ,ρ,β])
```
"""
struct ODESystem <: AbstractODESystem
    """The ODEs defining the system."""
    eqs::Vector{Equation}
    """Independent variable."""
    iv::Sym
    """Dependent (state) variables. Must not contain the independent variable."""
    states::Vector
    """Parameter variables. Must not contain the independent variable."""
    ps::Vector
    """Array variables."""
    var_to_name
    """Control parameters (some subset of `ps`)."""
    ctrls::Vector
    """Observed states."""
    observed::Vector{Equation}
    """
    Time-derivative matrix. Note: this field will not be defined until
    [`calculate_tgrad`](@ref) is called on the system.
    """
    tgrad::RefValue{Vector{Num}}
    """
    Jacobian matrix. Note: this field will not be defined until
    [`calculate_jacobian`](@ref) is called on the system.
    """
    jac::RefValue{Any}
    """
    Control Jacobian matrix. Note: this field will not be defined until
    [`calculate_control_jacobian`](@ref) is called on the system.
    """
    ctrl_jac::RefValue{Any}
    """
    `Wfact` matrix. Note: this field will not be defined until
    [`generate_factorized_W`](@ref) is called on the system.
    """
    Wfact::RefValue{Matrix{Num}}
    """
    `Wfact_t` matrix. Note: this field will not be defined until
    [`generate_factorized_W`](@ref) is called on the system.
    """
    Wfact_t::RefValue{Matrix{Num}}
    """
    Name: the name of the system
    """
    name::Symbol
    """
    systems: The internal systems. These are required to have unique names.
    """
    systems::Vector{ODESystem}
    """
    defaults: The default values to use when initial conditions and/or
    parameters are not supplied in `ODEProblem`.
    """
    defaults::Dict
    """
    structure: structural information of the system
    """
    structure::Any
    """
    connector_type: type of the system
    """
    connector_type::Any
    """
    connections: connections in a system
    """
    connections::Any
    """
    preface: inject assignment statements before the evaluation of the RHS function.
    """
    preface::Any
    """
    events: A `Vector{SymbolicContinuousCallback}` that model events.
    The integrator will use root finding to guarantee that it steps at each zero crossing.
    """
    continuous_events::Vector{SymbolicContinuousCallback}

    function ODESystem(deqs, iv, dvs, ps, var_to_name, ctrls, observed, tgrad, jac, ctrl_jac, Wfact, Wfact_t, name, systems, defaults, structure, connector_type, connections, preface, events; checks::Bool = true)
        if checks
            check_variables(dvs,iv)
            check_parameters(ps,iv)
            check_equations(deqs,iv)
            check_equations(equations(events),iv)
            all_dimensionless([dvs;ps;iv]) || check_units(deqs)
        end
        new(deqs, iv, dvs, ps, var_to_name, ctrls, observed, tgrad, jac, ctrl_jac, Wfact, Wfact_t, name, systems, defaults, structure, connector_type, connections, preface, events)
    end
end

function ODESystem(
                   deqs::AbstractVector{<:Equation}, iv, dvs, ps;
                   controls  = Num[],
                   observed = Equation[],
                   systems = ODESystem[],
                   name=nothing,
                   default_u0=Dict(),
                   default_p=Dict(),
                   defaults=_merge(Dict(default_u0), Dict(default_p)),
                   connector_type=nothing,
                   preface=nothing,
                   continuous_events=nothing,
                   checks = true,
                  )
    name === nothing && throw(ArgumentError("The `name` keyword must be provided. Please consider using the `@named` macro"))
    deqs = scalarize(deqs)
    @assert all(control -> any(isequal.(control, ps)), controls) "All controls must also be parameters."

    iv′ = value(scalarize(iv))
    dvs′ = value.(scalarize(dvs))
    ps′ = value.(scalarize(ps))
    ctrl′ = value.(scalarize(controls))

    if !(isempty(default_u0) && isempty(default_p))
        Base.depwarn("`default_u0` and `default_p` are deprecated. Use `defaults` instead.", :ODESystem, force=true)
    end
    defaults = todict(defaults)
    defaults = Dict{Any,Any}(value(k) => value(v) for (k, v) in pairs(defaults))

    var_to_name = Dict()
    process_variables!(var_to_name, defaults, dvs′)
    process_variables!(var_to_name, defaults, ps′)
    isempty(observed) || collect_var_to_name!(var_to_name, (eq.lhs for eq in observed))

    tgrad = RefValue(Vector{Num}(undef, 0))
    jac = RefValue{Any}(Matrix{Num}(undef, 0, 0))
    ctrl_jac = RefValue{Any}(Matrix{Num}(undef, 0, 0))
    Wfact   = RefValue(Matrix{Num}(undef, 0, 0))
    Wfact_t = RefValue(Matrix{Num}(undef, 0, 0))
    sysnames = nameof.(systems)
    if length(unique(sysnames)) != length(sysnames)
        throw(ArgumentError("System names must be unique."))
    end
    cont_callbacks = SymbolicContinuousCallbacks(continuous_events)
    ODESystem(deqs, iv′, dvs′, ps′, var_to_name, ctrl′, observed, tgrad, jac, ctrl_jac, Wfact, Wfact_t, name, systems, defaults, nothing, connector_type, nothing, preface, cont_callbacks, checks = checks)
end

function ODESystem(eqs, iv=nothing; kwargs...)
    eqs = scalarize(eqs)
    # NOTE: this assumes that the order of algebric equations doesn't matter
    diffvars = OrderedSet()
    allstates = OrderedSet()
    ps = OrderedSet()
    # reorder equations such that it is in the form of `diffeq, algeeq`
    diffeq = Equation[]
    algeeq = Equation[]
    # initial loop for finding `iv`
    if iv === nothing
        for eq in eqs
            if !(eq.lhs isa Number) # assume eq.lhs is either Differential or Number
                iv = iv_from_nested_derivative(eq.lhs)
                break
            end
        end
    end
    iv = value(iv)
    iv === nothing && throw(ArgumentError("Please pass in independent variables."))
    compressed_eqs = Equation[] # equations that need to be expanded later, like `connect(a, b)`
    for eq in eqs
        eq.lhs isa Union{Symbolic,Number} || (push!(compressed_eqs, eq); continue)
        collect_vars!(allstates, ps, eq.lhs, iv)
        collect_vars!(allstates, ps, eq.rhs, iv)
        if isdiffeq(eq)
            diffvar, _ = var_from_nested_derivative(eq.lhs)
            isequal(iv, iv_from_nested_derivative(eq.lhs)) || throw(ArgumentError("An ODESystem can only have one independent variable."))
            diffvar in diffvars && throw(ArgumentError("The differential variable $diffvar is not unique in the system of equations."))
            push!(diffvars, diffvar)
            push!(diffeq, eq)
        else
            push!(algeeq, eq)
        end
    end
    algevars = setdiff(allstates, diffvars)
    # the orders here are very important!
    return ODESystem(Equation[diffeq; algeeq; compressed_eqs], iv, collect(Iterators.flatten((diffvars, algevars))), ps; kwargs...)
end

# NOTE: equality does not check cached Jacobian
function Base.:(==)(sys1::ODESystem, sys2::ODESystem)
    sys1 === sys2 && return true
    iv1 = get_iv(sys1)
    iv2 = get_iv(sys2)
    isequal(iv1, iv2) &&
    isequal(nameof(sys1), nameof(sys2)) &&
    _eq_unordered(get_eqs(sys1), get_eqs(sys2)) &&
    _eq_unordered(get_states(sys1), get_states(sys2)) &&
    _eq_unordered(get_ps(sys1), get_ps(sys2)) &&
    all(s1 == s2 for (s1, s2) in zip(get_systems(sys1), get_systems(sys2)))
end

function flatten(sys::ODESystem)
    systems = get_systems(sys)
    if isempty(systems)
        return sys
    else
        return ODESystem(
                         equations(sys),
                         get_iv(sys),
                         states(sys),
                         parameters(sys),
                         observed=observed(sys),
                         continuous_events=continuous_events(sys),
                         defaults=defaults(sys),
                         name=nameof(sys),
                         checks = false,
                        )
    end
end

ODESystem(eq::Equation, args...; kwargs...) = ODESystem([eq], args...; kwargs...)

get_continuous_events(sys::AbstractSystem) = Equation[]
get_continuous_events(sys::AbstractODESystem) = getfield(sys, :continuous_events)
has_continuous_events(sys::AbstractSystem) = isdefined(sys, :continuous_events)
get_callback(prob::ODEProblem) = prob.kwargs[:callback]

"""
$(SIGNATURES)

Build the observed function assuming the observed equations are all explicit,
i.e. there are no cycles.
"""
function build_explicit_observed_function(
        sys, ts;
        expression=false,
        output_type=Array,
        checkbounds=true)

    if (isscalar = !(ts isa AbstractVector))
        ts = [ts]
    end
    ts = Symbolics.scalarize.(value.(ts))

    vars = Set()
    foreach(Base.Fix1(vars!, vars), ts)
    ivs = independent_variables(sys)
    dep_vars = scalarize(setdiff(vars, ivs))

    obs = observed(sys)
    sts = Set(states(sys))
    observed_idx = Dict(map(x->x.lhs, obs) .=> 1:length(obs))

    # FIXME: This is a rather rough estimate of dependencies. We assume
    # the expression depends on everything before the `maxidx`.
    maxidx = 0
    for (i, s) in enumerate(dep_vars)
        idx = get(observed_idx, s, nothing)
        if idx === nothing
            if !(s in sts)
                throw(ArgumentError("$s is either an observed nor a state variable."))
            end
            continue
        end
        idx > maxidx && (maxidx = idx)
    end
    obsexprs = map(eq -> eq.lhs←eq.rhs, obs[1:maxidx])

    dvs = DestructuredArgs(states(sys), inbounds=!checkbounds)
    ps = DestructuredArgs(parameters(sys), inbounds=!checkbounds)
    args = [dvs, ps, ivs...]
    pre = get_postprocess_fbody(sys)

    ex = Func(
        args, [],
        pre(Let(
            obsexprs,
            isscalar ? ts[1] : MakeArray(ts, output_type)
           ))
    ) |> toexpr
    expression ? ex : @RuntimeGeneratedFunction(ex)
end

function _eq_unordered(a, b)
    length(a) === length(b) || return false
    n = length(a)
    idxs = Set(1:n)
    for x ∈ a
        idx = findfirst(isequal(x), b)
        idx === nothing && return false
        idx ∈ idxs      || return false
        delete!(idxs, idx)
    end
    return true
end

# We have a stand-alone function to convert a `NonlinearSystem` or `ODESystem`
# to an `ODESystem` to connect systems, and we later can reply on
# `structural_simplify` to convert `ODESystem`s to `NonlinearSystem`s.
"""
$(TYPEDSIGNATURES)

Convert a `NonlinearSystem` to an `ODESystem` or converts an `ODESystem` to a
new `ODESystem` with a different independent variable.
"""
function convert_system(::Type{<:ODESystem}, sys, t; name=nameof(sys))
    isempty(observed(sys)) || throw(ArgumentError("`convert_system` cannot handle reduced model (i.e. observed(sys) is non-empty)."))
    t = value(t)
    varmap = Dict()
    sts = states(sys)
    newsts = similar(sts, Any)
    for (i, s) in enumerate(sts)
        if istree(s)
            args = arguments(s)
            length(args) == 1 || throw(InvalidSystemException("Illegal state: $s. The state can have at most one argument like `x(t)`."))
            arg = args[1]
            if isequal(arg, t)
                newsts[i] = s
                continue
            end
            ns = operation(s)(t)
            newsts[i] = ns
            varmap[s] = ns
        else
            ns = variable(getname(s); T=FnType)(t)
            newsts[i] = ns
            varmap[s] = ns
        end
    end
    sub = Base.Fix2(substitute, varmap)
    neweqs = map(sub, equations(sys))
    defs = Dict(sub(k) => sub(v) for (k, v) in defaults(sys))
    return ODESystem(neweqs, t, newsts, parameters(sys); defaults=defs, name=name,checks=false)
end
