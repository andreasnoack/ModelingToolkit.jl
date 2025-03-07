"""
$(TYPEDEF)

A system of difference equations.

# Fields
$(FIELDS)

# Example

```
using ModelingToolkit

@parameters σ=28.0 ρ=10.0 β=8/3 δt=0.1
@variables t x(t)=1.0 y(t)=0.0 z(t)=0.0
D = Difference(t; dt=δt)

eqs = [D(x) ~ σ*(y-x),
       D(y) ~ x*(ρ-z)-y,
       D(z) ~ x*y - β*z]

@named de = DiscreteSystem(eqs,t,[x,y,z],[σ,ρ,β]) # or 
@named de = DiscreteSystem(eqs)
```
"""
struct DiscreteSystem <: AbstractTimeDependentSystem
    """The differential equations defining the discrete system."""
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
    Name: the name of the system
    """
    name::Symbol
    """
    systems: The internal systems. These are required to have unique names.
    """
    systems::Vector{DiscreteSystem}
    """
    defaults: The default values to use when initial conditions and/or
    parameters are not supplied in `DiscreteProblem`.
    """
    defaults::Dict
    """
    type: type of the system
    """
    connector_type::Any
    function DiscreteSystem(discreteEqs, iv, dvs, ps, var_to_name, ctrls, observed, name, systems, defaults, connector_type; checks::Bool = true)
        if checks
            check_variables(dvs, iv)
            check_parameters(ps, iv)
            all_dimensionless([dvs;ps;iv;ctrls]) ||check_units(discreteEqs)
        end
        new(discreteEqs, iv, dvs, ps, var_to_name, ctrls, observed, name, systems, defaults, connector_type)
    end
end

"""
    $(TYPEDSIGNATURES)

Constructs a DiscreteSystem.
"""
function DiscreteSystem(
                   eqs::AbstractVector{<:Equation}, iv, dvs, ps;
                   controls = Num[],
                   observed = Num[],
                   systems = DiscreteSystem[],
                   name=nothing,
                   default_u0=Dict(),
                   default_p=Dict(),
                   defaults=_merge(Dict(default_u0), Dict(default_p)),
                   connector_type=nothing,
                   kwargs...,
                  )
    name === nothing && throw(ArgumentError("The `name` keyword must be provided. Please consider using the `@named` macro"))
    eqs = scalarize(eqs)
    iv′ = value(iv)
    dvs′ = value.(dvs)
    ps′ = value.(ps)
    ctrl′ = value.(controls)

    if !(isempty(default_u0) && isempty(default_p))
        Base.depwarn("`default_u0` and `default_p` are deprecated. Use `defaults` instead.", :DiscreteSystem, force=true)
    end
    defaults = todict(defaults)
    defaults = Dict(value(k) => value(v) for (k, v) in pairs(defaults))

    var_to_name = Dict()
    process_variables!(var_to_name, defaults, dvs′)
    process_variables!(var_to_name, defaults, ps′)
    isempty(observed) || collect_var_to_name!(var_to_name, (eq.lhs for eq in observed))
    
    sysnames = nameof.(systems)
    if length(unique(sysnames)) != length(sysnames)
        throw(ArgumentError("System names must be unique."))
    end
    DiscreteSystem(eqs, iv′, dvs′, ps′, var_to_name, ctrl′, observed, name, systems, defaults, connector_type, kwargs...)
end


function DiscreteSystem(eqs, iv=nothing; kwargs...)
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
                iv = iv_from_nested_difference(eq.lhs)
                break
            end
        end
    end
    iv = value(iv)
    iv === nothing && throw(ArgumentError("Please pass in independent variables."))
    for eq in eqs
        collect_vars_difference!(allstates, ps, eq.lhs, iv)
        collect_vars_difference!(allstates, ps, eq.rhs, iv)
        if isdifferenceeq(eq)
            diffvar, _ = var_from_nested_difference(eq.lhs)
            isequal(iv, iv_from_nested_difference(eq.lhs)) || throw(ArgumentError("A DiscreteSystem can only have one independent variable."))
            diffvar in diffvars && throw(ArgumentError("The difference variable $diffvar is not unique in the system of equations."))
            push!(diffvars, diffvar)
            push!(diffeq, eq)
        else
            push!(algeeq, eq)
        end
    end
    algevars = setdiff(allstates, diffvars)
    # the orders here are very important!
    return DiscreteSystem(append!(diffeq, algeeq), iv, collect(Iterators.flatten((diffvars, algevars))), ps; kwargs...)
end

"""
    $(TYPEDSIGNATURES)

Generates an DiscreteProblem from an DiscreteSystem.
"""
function DiffEqBase.DiscreteProblem(sys::DiscreteSystem,u0map,tspan,
                                    parammap=DiffEqBase.NullParameters();
                                    eval_module = @__MODULE__,
                                    eval_expression = true,
                                    kwargs...)
    dvs = states(sys)
    ps = parameters(sys)
    eqs = equations(sys)
    eqs = linearize_eqs(sys, eqs)
    defs = defaults(sys)
    iv = get_iv(sys)

    if parammap isa Dict
        u0defs = merge(parammap, defs)
    elseif eltype(parammap) <: Pair
        u0defs = merge(Dict(parammap), defs)
    elseif eltype(parammap) <: Number
        u0defs = merge(Dict(zip(ps, parammap)), defs)
    else
        u0defs = defs
    end
    if u0map isa Dict
        pdefs = merge(u0map, defs)
    elseif eltype(u0map) <: Pair
        pdefs = merge(Dict(u0map), defs)
    elseif eltype(u0map) <: Number
        pdefs = merge(Dict(zip(dvs, u0map)), defs)
    else
        pdefs = defs
    end

    u0 = varmap_to_vars(u0map,dvs; defaults=u0defs)
    
    rhss = [eq.rhs for eq in eqs]
    u = dvs
    p = varmap_to_vars(parammap,ps; defaults=pdefs)

    f_gen = generate_function(sys; expression=Val{eval_expression}, expression_module=eval_module)
    f_oop, _ = (@RuntimeGeneratedFunction(eval_module, ex) for ex in f_gen)
    f(u,p,iv) = f_oop(u,p,iv)
    fd = DiscreteFunction(f, syms=Symbol.(dvs))
    DiscreteProblem(fd,u0,tspan,p;kwargs...)
end

function linearize_eqs(sys, eqs=get_eqs(sys); return_max_delay=false)
    unique_states = unique(operation.(states(sys)))
    max_delay = Dict(v=>0.0 for v in unique_states)

    r = @rule ~t::(t -> istree(t) && any(isequal(operation(t)), operation.(states(sys))) && is_delay_var(get_iv(sys), t)) => begin
        delay = get_delay_val(get_iv(sys), first(arguments(~t)))
        if delay > max_delay[operation(~t)]
            max_delay[operation(~t)] = delay
        end
        nothing
    end
    SymbolicUtils.Postwalk(r).(rhss(eqs))

    if any(values(max_delay) .> 0)

        dts = Dict(v=>Any[] for v in unique_states)
        state_ops = Dict(v=>Any[] for v in unique_states)
        for v in unique_states
            for eq in eqs
                if isdifferenceeq(eq) && istree(arguments(eq.lhs)[1]) && isequal(v, operation(arguments(eq.lhs)[1]))
                    append!(dts[v], [operation(eq.lhs).dt])
                    append!(state_ops[v], [operation(eq.lhs)])
                end
            end
        end

        all(length.(unique.(values(state_ops))) .<= 1) || error("Each state should be used with single difference operator.")
        
        dts_gcd = Dict()
        for v in keys(dts)
            dts_gcd[v] = (length(dts[v]) > 0) ? first(dts[v]) : nothing
        end

        lin_eqs = [
            v(get_iv(sys) - (t)) ~ v(get_iv(sys) - (t-dts_gcd[v]))
            for v in unique_states if max_delay[v] > 0 && dts_gcd[v]!==nothing for t in collect(max_delay[v]:(-dts_gcd[v]):0)[1:end-1] 
        ]
        eqs = vcat(eqs, lin_eqs)
    end
    if return_max_delay return eqs, max_delay end
    eqs
end

function get_delay_val(iv, x)
    delay = x - iv
    isequal(delay > 0, true) && error("Forward delay not permitted")
    return -delay
end

check_difference_variables(eq) = check_operator_variables(eq, Difference)

function generate_function(
        sys::DiscreteSystem, dvs = states(sys), ps = parameters(sys);
        kwargs...
    )
    eqs = equations(sys)
    foreach(check_difference_variables, eqs)
    # substitute x(t) by just x
    rhss = [eq.rhs for eq in eqs]

    u = map(x->time_varying_as_func(value(x), sys), dvs)
    p = map(x->time_varying_as_func(value(x), sys), ps)
    t = get_iv(sys)
    
    build_function(rhss, u, p, t; kwargs...)
end
