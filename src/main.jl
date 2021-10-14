include("domains.jl")
include("parameters.jl")
# stdlib
using LinearAlgebra, Logging, Printf

# JSO packages
using Krylov, LinearOperators, NLPModels, NLPModelsModifiers, SolverCore, SolverTools, ADNLPModels, SolverTest

using NOMAD

""" lbfgs"""
mutable struct LBFGSSolver{T,V,Op<:AbstractLinearOperator,P<:AbstractHyperParameter,M<:AbstractNLPModel}
    p::AbstractVector{P}
    x::V
    xt::V
    gx::V
    gt::V
    d::V
    H::Op
    h::LineModel{T,V,M}
end

function LBFGSSolver(
    nlp::M,
    parameters::AbstractVector{P},
) where {T,V,P<:AbstractHyperParameter,M<:AbstractNLPModel{T,V}}
    nvar = nlp.meta.nvar
    x = V(undef, nvar)
    d = V(undef, nvar)
    xt = V(undef, nvar)
    gx = V(undef, nvar)
    gt = V(undef, nvar)
    p  = parameters
    memory = find(p, "mem")
    H = InverseLBFGSOperator(T, nvar, mem = default(memory), scaling = true)
    h = LineModel(nlp, x, d)
    Op = typeof(H)
    return LBFGSSolver{T,V,Op,P,M}(p, x, xt, gx, gt, d, H, h)
end

# @doc (@doc LBFGSSolver) function lbfgs(
#     solver::LBFGSSolver{T,V},
#     nlp::AbstractNLPModel;
#     x::V = nlp.meta.x0,
#     kwargs...,
# ) where {T,V}
#     solver = LBFGSSolver(nlp, lbfgs_params)
#     return solve!(solver, nlp; x = x, kwargs...)
# end

@doc (@doc LBFGSSolver) function lbfgs(
    nlp::AbstractNLPModel, parameters::AbstractVector{P};
    x::V = nlp.meta.x0,
    kwargs...,
) where {V, P<:AbstractHyperParameter}
    solver = LBFGSSolver(nlp, parameters)
    return solve!(solver, nlp; x = x, kwargs...)
end

function solve!(
    solver::LBFGSSolver{T,V},
    nlp::AbstractNLPModel{T,V};
    x::V = nlp.meta.x0,
    atol::Real = √eps(T),
    rtol::Real = √eps(T),
    max_eval::Int = -1,
    max_time::Float64 = 30.0,
    verbose::Bool = true,
) where {T,V}
    if !(nlp.meta.minimize)
        error("lbfgs only works for minimization problem")
    end
    if !unconstrained(nlp)
        error("lbfgs should only be called for unconstrained problems. Try tron instead")
    end

    start_time = time()
    elapsed_time = 0.0

    n = nlp.meta.nvar

    solver.x .= x
    x = solver.x
    xt = solver.xt
    ∇f = solver.gx
    ∇ft = solver.gt
    d = solver.d
    h = solver.h
    H = solver.H
    reset!(H)

    f = obj(nlp, x)
    grad!(nlp, x, ∇f)

    ∇fNorm = nrm2(n, ∇f)
    ϵ = atol + rtol * ∇fNorm
    iter = 0

    @info log_header(
        [:iter, :f, :dual, :slope, :bk],
        [Int, T, T, T, Int],
        hdr_override = Dict(:f => "f(x)", :dual => "‖∇f‖", :slope => "∇fᵀd"),
    )

    optimal = ∇fNorm ≤ ϵ
    tired = neval_obj(nlp) > max_eval ≥ 0 || elapsed_time > max_time
    stalled = false
    status = :unknown

    while !(optimal || tired || stalled)
        mul!(d, H, ∇f, -one(T), zero(T))
        slope = dot(n, d, ∇f)
        if slope ≥ 0
            @error "not a descent direction" slope
            status = :not_desc
            stalled = true
            continue
        end

        # Perform improved Armijo linesearch.
        τ₁_slope_factor = default(find(solver.p, "τ₁"))
        t, good_grad, ft, nbk, nbW =
            armijo_wolfe(h, f, slope, ∇ft, τ₁ = τ₁_slope_factor, bk_max = 25, verbose = false)

        @info log_row(Any[iter, f, ∇fNorm, slope, nbk])

        copyaxpy!(n, t, d, x, xt)
        good_grad || grad!(nlp, xt, ∇ft)

        # Update L-BFGS approximation.
        d .*= t
        @. ∇f = ∇ft - ∇f
        push!(H, d, ∇f)

        # Move on.
        x .= xt
        f = ft
        ∇f .= ∇ft

        ∇fNorm = nrm2(n, ∇f)
        iter = iter + 1

        optimal = ∇fNorm ≤ ϵ
        elapsed_time = time() - start_time
        tired = neval_obj(nlp) > max_eval ≥ 0 || elapsed_time > max_time
    end
    @info log_row(Any[iter, f, ∇fNorm])

    if optimal
        status = :first_order
    elseif tired
        if neval_obj(nlp) > max_eval ≥ 0
            status = :max_eval
        elseif elapsed_time > max_time
            status = :max_time
        end
    end

    return GenericExecutionStats(
        status,
        nlp,
        solution = x,
        objective = f,
        dual_feas = ∇fNorm,
        iter = iter,
        elapsed_time = elapsed_time,
    )
end

# create structure that encapsulates the necessary info to pass to the objective function
# solver, parameters, 
# function objective_func(vec::AbstractVector{T}) where T
#     println("new values: $vec")
#     return true, true, bb_output(vec)
# end

# function evaluation_func(vec::AbstractVector{Float64})
#     parameters = problem.solver.p
#     [update_parameter(param, param_value) for (param, param_value) in zip(parameters, vec)]
#     return true, true, bb_output(parameters)
# end

function main()
    nlp = ADNLPModel(x -> (x[1] - 1)^2 + 4 * (x[2] - 1)^2, zeros(2), name = "(x₁ - 1)² + 4(x₂ - 1)²")
    mem = AlgorithmicParameter(1, IntegerRange(1, length(nlp.meta.x0)), "mem")
    τ₁ = AlgorithmicParameter(Float64(0.99), RealInterval(Float64(1.0e-4), 2.0), "τ₁")
    lbfgs_params = [mem, τ₁]
    solver = LBFGSSolver(nlp, lbfgs_params)
    param_optimization_problem = ParameterOptimizationProblem(solver)
    result = minimize_with_nomad!(param_optimization_problem)
    println(result)
end

main()