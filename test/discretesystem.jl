# Example: Compartmental models in epidemiology
#=
- https://github.com/epirecipes/sir-julia/blob/master/markdown/function_map/function_map.md
- https://en.wikipedia.org/wiki/Compartmental_models_in_epidemiology#Deterministic_versus_stochastic_epidemic_models
=#
using ModelingToolkit, Test

@inline function rate_to_proportion(r,t)
    1-exp(-r*t)
end;

# Independent and dependent variables and parameters
@parameters t c nsteps δt β γ
D = Difference(t; dt=0.1)
@variables S(t) I(t) R(t)

infection = rate_to_proportion(β*c*I/(S+I+R),δt)*S
recovery = rate_to_proportion(γ,δt)*I

# Equations
eqs = [D(S) ~ S-infection,
       D(I) ~ I+infection-recovery,
       D(R) ~ R+recovery]

# System
@named sys = DiscreteSystem(eqs,t,[S,I,R],[c,nsteps,δt,β,γ]; controls = [β, γ])

# Problem
u0 = [S => 990.0, I => 10.0, R => 0.0]
p = [β => 0.05, c => 10.0, γ => 0.25, δt => 0.1, nsteps => 400]
tspan = (0.0,ModelingToolkit.value(substitute(nsteps,p))) # value function (from Symbolics) is used to convert a Num to Float64
prob_map = DiscreteProblem(sys,u0,tspan,p)

# Solution
using OrdinaryDiffEq
sol_map = solve(prob_map,FunctionMap());
@test sol_map[S] isa Vector

# Using defaults constructor
@parameters t c=10.0 nsteps=400 δt=0.1 β=0.05 γ=0.25
Diff = Difference(t; dt=0.1)
@variables S(t)=990.0 I(t)=10.0 R(t)=0.0

infection2 = rate_to_proportion(β*c*I/(S+I+R),δt)*S
recovery2 = rate_to_proportion(γ,δt)*I

eqs2 = [D(S) ~ S-infection2,
       D(I) ~ I+infection2-recovery2,
       D(R) ~ R+recovery2]

@named sys = DiscreteSystem(eqs2; controls = [β, γ])
@test ModelingToolkit.defaults(sys) != Dict()

prob_map2 = DiscreteProblem(sys,[],tspan)
sol_map2 = solve(prob_map,FunctionMap());

@test sol_map.u == sol_map2.u
@test sol_map.prob.p == sol_map2.prob.p

# Direct Implementation

function sir_map!(u_diff,u,p,t)
    (S,I,R) = u
    (β,c,γ,δt) = p
    N = S+I+R
    infection = rate_to_proportion(β*c*I/N,δt)*S
    recovery = rate_to_proportion(γ,δt)*I
    @inbounds begin
        u_diff[1] = S-infection
        u_diff[2] = I+infection-recovery
        u_diff[3] = R+recovery
    end
    nothing
end;
u0 = [990.0,10.0,0.0];
p = [0.05,10.0,0.25,0.1];
prob_map = DiscreteProblem(sir_map!,u0,tspan,p);
sol_map2 = solve(prob_map,FunctionMap());

@test Array(sol_map) ≈ Array(sol_map2)

# Delayed difference equation
@parameters t
@variables x(..) y(..) z(t)
D1 = Difference(t; dt=1.5)
D2 = Difference(t; dt=2)

@test ModelingToolkit.is_delay_var(Symbolics.value(t), Symbolics.value(x(t-2)))
@test ModelingToolkit.is_delay_var(Symbolics.value(t), Symbolics.value(y(t-1)))
@test !ModelingToolkit.is_delay_var(Symbolics.value(t), Symbolics.value(z))
@test_throws ErrorException ModelingToolkit.get_delay_val(Symbolics.value(t), Symbolics.arguments(Symbolics.value(x(t+2)))[1])
@test_throws ErrorException z(t)

# Equations
eqs = [
    D1(x(t)) ~ 0.4x(t) + 0.3x(t-1.5) + 0.1x(t-3),
    D2(y(t)) ~ 0.3y(t) + 0.7y(t-2) + 0.1z,
]

# System
@named sys = DiscreteSystem(eqs,t,[x(t),x(t-1.5),x(t-3),y(t),y(t-2),z],[])

eqs2, max_delay = ModelingToolkit.linearize_eqs(sys; return_max_delay=true)

@test max_delay[Symbolics.operation(Symbolics.value(x(t)))] ≈ 3
@test max_delay[Symbolics.operation(Symbolics.value(y(t)))] ≈ 2

linearized_eqs = [
    eqs
    x(t - 3.0) ~ x(t - 1.5)
    x(t - 1.5) ~ x(t)
    y(t - 2.0) ~ y(t)
]
@test all(eqs2 .== linearized_eqs)

# observed variable handling
@variables t x(t) RHS(t)
@parameters τ   
@named fol = DiscreteSystem([D(x) ~ (1 - x)/τ]; observed=[RHS ~ (1 - x)/τ])
@test isequal(RHS, @nonamespace fol.RHS)
RHS2 = RHS
@unpack RHS = fol
@test isequal(RHS, RHS2)
