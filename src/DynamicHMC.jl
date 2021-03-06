__precompile__()
module DynamicHMC

import Base: rand, length, show
import Base.LinAlg.checksquare

using ArgCheck: @argcheck
import Compat                   # for DomainError(val, msg) in v0.6
using DataStructures
using DiffResults: value, gradient
using DocStringExtensions: SIGNATURES, FIELDS
using Parameters: @unpack
import StatsFuns: logsumexp

export
    # Hamiltonian
    KineticEnergy, EuclideanKE, GaussianKE,
    # transition
    NUTS_Transition, get_position, get_neg_energy, get_depth, get_termination,
    get_acceptance_rate, get_steps, NUTS, mcmc, mcmc_adapting_ϵ,
    # tuning and diagnostics
    NUTS_init_tune_mcmc, sample_cov, EBFMI, NUTS_statistics, get_position_matrix


# Hamiltonian and leapfrog

"""
Kinetic energy specifications.

For all subtypes, it is assumed that kinetic energy is symmetric in
the momentum `p`, ie.

```julia
neg_energy(::KineticEnergy, p, q) == neg_energy(::KineticEnergy, -p, q)
```

When the above is violated, various implicit assumptions will not hold.
"""
abstract type KineticEnergy end

"Euclidean kinetic energies (position independent)."
abstract type EuclideanKE <: KineticEnergy end

"""
Gaussian kinetic energy.

```math
p \\mid q ∼ \\text{Normal}(0, M) \\qquad (\\text{importantly, independent of \$q\$})
```

The inverse covariance `M⁻¹` is stored.
"""
struct GaussianKE{T <: AbstractMatrix, S <: AbstractMatrix} <: EuclideanKE
    "M⁻¹"
    Minv::T
    "W such that W*W'=M. Used for generating random draws."
    W::S
    function GaussianKE{T, S}(Minv, W) where {T, S}
        @argcheck checksquare(Minv) == checksquare(W)
        new(Minv, W)
    end
end

GaussianKE(M::T, W::S) where {T,S} = GaussianKE{T,S}(M, W)

"""
    GaussianKE(M⁻¹::AbstractMatrix)

Gaussian kinetic energy with the given inverse covariance matrix `M⁻¹`.
"""
GaussianKE(Minv::AbstractMatrix) = GaussianKE(Minv, inv(chol(Minv)))

"""
    GaussianKE(N::Int, [m⁻¹ = 1.0])

Gaussian kinetic energy with a diagonal inverse covariance matrix `M⁻¹=m⁻¹*I`.
"""
GaussianKE(N::Int, m⁻¹ = 1.0) = GaussianKE(Diagonal(fill(m⁻¹, N)))

show(io::IO, κ::GaussianKE) =
    print(io::IO, "Gaussian kinetic energy, √diag(M⁻¹): $(.√(diag(κ.Minv)))")

"""
    neg_energy(κ, p, [q])

Return the log density of kinetic energy `κ`, at momentum `p`. Some kinetic
energies (eg Riemannian geometry) will need `q`, too.
"""
neg_energy(κ::GaussianKE, p, q = nothing) = -dot(p, κ.Minv * p) / 2

"""
    get_p♯(κ, p, [q])

Return ``p\sharp``, used for turn diagnostics.
"""
get_p♯(κ::GaussianKE, p, q = nothing) = κ.Minv * p

loggradient(κ::GaussianKE, p, q = nothing) = -get_p♯(κ, p)

rand(rng, κ::GaussianKE, q = nothing) = κ.W * randn(rng, size(κ.W, 1))

"""
    Hamiltonian(ℓ, κ)

Construct a Hamiltonian from the log density `ℓ`, and the kinetic energy
specification `κ`. Calls of `ℓ` with a vector are expected to return a value
that supports `DiffResults.value` and `DiffResults.gradient`.
"""
struct Hamiltonian{Tℓ, Tκ}
    "The (log) density we are sampling from."
    ℓ::Tℓ
    "The kinetic energy."
    κ::Tκ
end

show(io::IO, H::Hamiltonian) = print(io, "Hamiltonian with $(H.κ)")

"""
    is_valid_ℓq(ℓq)

Test that a value returned by ℓ is *valid*, in the following sense:

1. supports `DiffResults.value` and `DiffResults.gradient` (when not, a
`MethodError` is thrown),

2. the value is a float, either `-Inf` or finite,

3. the gradient is finite when the value is; otherwise the gradient is ignored.
"""
function is_valid_ℓq(ℓq)
    v = value(ℓq)
    v isa AbstractFloat || return false
    (v == -Inf) || (isfinite(v) && all(isfinite, gradient(ℓq)))
end

"""
A point in phase space, consists of a position and a momentum.

Log densities and gradients are saved for speed gains, so that the gradient of ℓ
at q is not calculated twice for every leapfrog step (both as start- and
endpoints).

Because of caching, a `PhasePoint` should only be used with a specific
Hamiltonian.
"""
struct PhasePoint{T,S}
    "Position."
    q::T
    "Momentum."
    p::T
    "ℓ(q). Cached for reuse in sampling."
    ℓq::S
    function PhasePoint(q::T, p::T, ℓq::S) where {T,S}
        @argcheck is_valid_ℓq(ℓq) DomainError("Invalid value of ℓ.")
        @argcheck length(p) == length(q)
        new{T,S}(q, p, ℓq)
    end
end

"""
    get_ℓq(z)

The value returned by `ℓ` when evaluated at position `q`.
"""
get_ℓq(z::PhasePoint) = z.ℓq

"""
    phasepoint_in(H::Hamiltonian, q, p)

The recommended interface for creating a phase point in a Hamiltonian. Computes
cached values.
"""
phasepoint_in(H::Hamiltonian, q, p) = PhasePoint(q, p, H.ℓ(q))

"""
    rand_phasepoint(rng, H, q)

Extend a position `q` to a phasepoint with a random momentum according to the
kinetic energy of `H`.
"""
rand_phasepoint(rng, H, q) = phasepoint_in(H, q, rand(rng, H.κ))

"""
    $SIGNATURES

Log density for Hamiltonian `H` at point `z`.

If `ℓ(q) == -Inf` (rejected), ignores the kinetic energy.
"""
function neg_energy(H::Hamiltonian, z::PhasePoint)
    v = value(get_ℓq(z))
    v == -Inf ? v : (v + neg_energy(H.κ, z.p, z.q))
end

get_p♯(H::Hamiltonian, z::PhasePoint) = get_p♯(H.κ, z.p, z.q)

"""
    leapfrog(H, z, ϵ)

Take a leapfrog step of length `ϵ` from `z` along the Hamiltonian `H`.

Return the new position.

The leapfrog algorithm uses the gradient of the next position to evolve the
momentum. If this is not finite, the momentum won't be either. Since the
constructor `PhasePoint` validates its arguments, this can only happen for
divergent points anyway, and should not cause a problem.
"""
function leapfrog{Tℓ, Tκ <: EuclideanKE}(H::Hamiltonian{Tℓ,Tκ}, z::PhasePoint, ϵ)
    @unpack ℓ, κ = H
    @unpack p, q, ℓq = z
    pₘ = p + ϵ/2 * gradient(ℓq)
    q′ = q - ϵ * loggradient(κ, pₘ)
    ℓq′ = ℓ(q′)
    p′ = pₘ + ϵ/2 * gradient(ℓq′)
    PhasePoint(q′, p′, ℓq′)
end


# stepsize heuristics and adaptation

"""
Parameters for the search algorithm for the initial stepsize.

The algorithm finds an initial stepsize ``ϵ`` so that the local acceptance ratio
``A(ϵ)`` satisfies

```math
a_\\text{min} ≤ A(ϵ) ≤ a_\\text{max}
```

This is achieved by an initial bracketing, then bisection.

$FIELDS

!!! note

    Cf. Hoffman and Gelman (2014), which does not ensure bounds for the
    acceptance ratio, just that it has crossed a threshold. This version seems
    to work better for some tricky posteriors with high curvature.
"""
struct InitialStepsizeSearch
    "Lowest local acceptance rate."
    a_min::Float64
    "Highest local acceptance rate."
    a_max::Float64
    "Initial stepsize."
    ϵ₀::Float64
    "Scale factor for initial bracketing, > 1. *Default*: `2.0`."
    C::Float64
    "Maximum number of iterations for initial bracketing."
    maxiter_crossing::Int
    "Maximum number of iterations for bisection."
    maxiter_bisect::Int
    function InitialStepsizeSearch(; a_min = 0.25, a_max = 0.75, ϵ₀ = 1.0,
                                   C = 2.0,
                                   maxiter_crossing = 400, maxiter_bisect = 400)
        @argcheck 0 < a_min < a_max < 1
        @argcheck 0 < ϵ₀
        @argcheck 1 < C
        @argcheck maxiter_crossing ≥ 50
        @argcheck maxiter_bisect ≥ 50
        new(a_min, a_max, ϵ₀, C, maxiter_crossing, maxiter_bisect)
    end
end

"""
Find the stepsize for which the local acceptance rate `A(ϵ)` crosses `a`.

    $SIGNATURES

Return `ϵ₀, A(ϵ₀), ϵ₁`, A(ϵ₁)`, where `ϵ₀` and `ϵ₁` are stepsizes before and
after crossing `a` with `A(ϵ)`, respectively.

Assumes that ``A(ϵ₀) ∉ (a_\\text{min}, a_\\text{max})``, where the latter are
defined in `parameters`.

- `parameters`: parameters for the iteration.

- `A`: local acceptance ratio (uncapped), a function of stepsize `ϵ`

- `ϵ₀`, `Aϵ₀`: initial value of `ϵ`, and `A(ϵ₀)`
"""
function find_crossing_stepsize(parameters, A, ϵ₀, Aϵ₀ = A(ϵ₀))
    @unpack a_min, a_max, C, maxiter_crossing = parameters
    s, a = Aϵ₀ > a_max ? (1.0, a_max) : (-1.0, a_min)
    if s < 0                    # when A(ϵ) < a,
        C = 1/C                 # decrease ϵ
    end
    for _ in 1:maxiter_crossing
        ϵ = ϵ₀ * C
        Aϵ = A(ϵ)
        if s*(Aϵ - a) ≤ 0
            return ϵ₀, Aϵ₀, ϵ, Aϵ
        else
            ϵ₀ = ϵ
            Aϵ₀ = Aϵ
        end
    end
    # should never each this, miscoded log density?
    dir = s > 0 ? "below" : "above"
    error("Reached maximum number of iterations searching for ϵ from $(dir).")
end

"""
Return the desired stepsize `ϵ` by bisection.

    $SIGNATURES

- `parameters`: algorithm parameters, see [`InitialStepsizeSearch`](@ref)

- `A`: local acceptance ratio (uncapped), a function of stepsize `ϵ`

- `ϵ₀`, `ϵ₁`, `Aϵ₀`, `Aϵ₁`: stepsizes and acceptance rates (latter optional).

This function assumes that ``ϵ₀ < ϵ₁``, the stepsize is not yet acceptable, and
the cached `A` values have the correct ordering.
"""
function bisect_stepsize(parameters, A, ϵ₀, ϵ₁, Aϵ₀ = A(ϵ₀), Aϵ₁ = A(ϵ₁))
    @unpack a_min, a_max, maxiter_bisect = parameters
    @argcheck ϵ₀ < ϵ₁
    @argcheck Aϵ₀ > a_max && Aϵ₁ < a_min
    for _ in 1:maxiter_bisect
        ϵₘ = middle(ϵ₀, ϵ₁)
        Aϵₘ = A(ϵₘ)
        if a_min ≤ Aϵₘ ≤ a_max  # in
            return ϵₘ
        elseif Aϵₘ < a_min      # above
            ϵ₁ = ϵₘ
            Aϵ₁ = Aϵₘ
        else                    # below
            ϵ₀ = ϵₘ
            Aϵ₀ = Aϵₘ
        end
    end
    # should never each this, miscoded log density?
    error("Reached maximum number of iterations while bisecting interval for ϵ.")
end

"""
    $SIGNATURES

Find an initial stepsize that matches the conditions of `parameters` (see
[`InitialStepsizeSearch`](@ref)).

`A` is the local acceptance ratio (uncapped). When given a Hamiltonian `H` and a
phasepoint `z`, it will be calculated using [`local_acceptance_ratio`](@ref).
"""
function find_initial_stepsize(parameters::InitialStepsizeSearch, A)
    @unpack a_min, a_max, ϵ₀ = parameters
    Aϵ₀ = A(ϵ₀)
    if a_min ≤ Aϵ₀ ≤ a_max
        ϵ₀
    else
        ϵ₀, Aϵ₀, ϵ₁, Aϵ₁ = find_crossing_stepsize(parameters, A, ϵ₀, Aϵ₀)
        if a_min ≤ Aϵ₁ ≤ a_max  # in interval
            ϵ₁
        elseif ϵ₀ < ϵ₁          # order as necessary
            bisect_stepsize(parameters, A, ϵ₀, ϵ₁, Aϵ₀, Aϵ₁)
        else
            bisect_stepsize(parameters, A, ϵ₁, ϵ₀, Aϵ₁, Aϵ₀)
        end
    end
end

find_initial_stepsize(parameters::InitialStepsizeSearch, H, z) =
    find_initial_stepsize(parameters, local_acceptance_ratio(H, z))

"""
    $(SIGNATURES)

Return a function of the stepsize (``ϵ``) that calculates the local acceptance
ratio for a single leapfrog step around `z` along the Hamiltonian `H`. Formally,
let

```math
A(ϵ) = \\exp(\\text{neg_energy}(H, \\text{leapfrog}(H, z, ϵ)) - \\text{neg_energy}(H, z))
```

Note that the ratio is not capped by `1`, so it is not a valid probability
*per se*.
"""
function local_acceptance_ratio(H, z)
    target = neg_energy(H, z)
    isfinite(target) ||
        throw(DomainError(z.p, "Starting point has non-finite density."))
    ϵ -> exp(neg_energy(H, leapfrog(H, z, ϵ)) - target)
end

"""
    $(SIGNATURES)

Return a matrix of [`local_acceptance_ratio`](@ref) values for stepsizes `ϵs`
and the given momentums `ps`. The latter is calculated from random values when
an integer is given.

To facilitate plotting, ``-∞`` values are replaced by `NaN`.
"""
function explore_local_acceptance_ratios(H, q, ϵs, ps)
    R = hcat([local_acceptance_ratio(H, q, p).(ϵs) for p in ps]...)
    R[isinfinite.(R)] .= NaN
    R
end

explore_local_acceptance_ratios(H, q, ϵs, N::Int) =
    explore_local_acceptance_ratios(H, q, ϵs, [rand(H.κ) for _ in 1:N])

"""
Parameters for the dual averaging algorithm of Gelman and Hoffman (2014,
Algorithm 6).

To get reasonable defaults, initialize with
`DualAveragingParameters(logϵ₀)`. See [`adapting_ϵ`](@ref) for a joint
constructor.
"""
struct DualAveragingParameters{T}
    μ::T
    "target acceptance rate"
    δ::T
    "regularization scale"
    γ::T
    "relaxation exponent"
    κ::T
    "offset"
    t₀::Int
    function DualAveragingParameters{T}(μ, δ, γ, κ, t₀) where {T}
        @argcheck 0 < δ < 1
        @argcheck γ > 0
        @argcheck 0.5 < κ ≤ 1
        @argcheck t₀ ≥ 0
        new(μ, δ, γ, κ, t₀)
    end
end

DualAveragingParameters(μ::T, δ::T, γ::T, κ::T, t₀::Int) where T =
    DualAveragingParameters{T}(μ, δ, γ, κ, t₀)

DualAveragingParameters(logϵ₀; δ = 0.8, γ = 0.05, κ = 0.75, t₀ = 10) =
    DualAveragingParameters(promote(log(10) + logϵ₀, δ, γ, κ)..., t₀)

"Current state of adaptation for `ϵ`. Use `DualAverageingAdaptation(logϵ₀)` to
get an initial value. See [`adapting_ϵ`](@ref) for a joint constructor."
struct DualAveragingAdaptation{T <: AbstractFloat}
    m::Int
    H̄::T
    logϵ::T
    logϵ̄::T
end

"""
    get_ϵ(A, tuning = true)

When `tuning`, return the stepsize `ϵ` for the next HMC step. Otherwise return
the tuned `ϵ`.
"""
get_ϵ(A::DualAveragingAdaptation, tuning = true) = exp(tuning ? A.logϵ : A.logϵ̄)

DualAveragingAdaptation(logϵ₀) =
    DualAveragingAdaptation(0, zero(logϵ₀), logϵ₀, zero(logϵ₀))

"""
    DA_params, A = adapting_ϵ(ϵ; args...)

Constructor for both the adaptation parameters and the initial state.
"""
function adapting_ϵ(ϵ; args...)
    logϵ = log(ϵ)
    DualAveragingParameters(logϵ; args...), DualAveragingAdaptation(logϵ)
end

"""
    A′ = adapt_stepsize(parameters, A, a)

Update the adaptation `A` of log stepsize `logϵ` with average Metropolis
acceptance rate `a` over the whole visited trajectory, using the dual averaging
algorithm of Gelman and Hoffman (2014, Algorithm 6). Return the new adaptation.
"""
function adapt_stepsize(parameters::DualAveragingParameters,
                        A::DualAveragingAdaptation, a)
    @argcheck 0 ≤ a ≤ 1
    @unpack μ, δ, γ, κ, t₀ = parameters
    @unpack m, H̄, logϵ, logϵ̄ = A
    m += 1
    H̄ += (δ - a - H̄) / (m+t₀)
    logϵ = μ - √m/γ*H̄
    logϵ̄ += m^(-κ)*(logϵ - logϵ̄)
    DualAveragingAdaptation(m, H̄, logϵ, logϵ̄)
end

# random booleans

"""
    rand_bool(rng, prob)

Random boolean which is `true` with the given probability `prob`.

All random numbers in this library are obtained from this function.
"""
rand_bool{T <: AbstractFloat}(rng, prob::T) = rand(rng, T) ≤ prob


# abstract trajectory interface

"""
    ζ, τ, d, z = adjacent_tree(rng, trajectory, z, depth, fwd)

Traverse the tree of given `depth` adjacent to point `z` in `trajectory`.

`fwd` specifies the direction, `rng` is used for random numbers.

Return:

- `ζ`: the proposal from the tree. Only valid when `!isdivergent(d) &&
  !isturning(τ)`, otherwise the value should not be used.

- `τ`: turn statistics. Only valid when `!isdivergent(d)`.

- `d`: divergence statistics, always valid.

- `z`: the point at the end of the tree.

`trajectory` should support the following interface:

- Starting from leaves: `ζ, τ, d = leaf(trajectory, z, isinitial)`

- Moving along the trajectory: `z = move(trajectory, z, fwd)`

- Testing for turning and divergence: `isturning(τ)`, `isdivergent(d)`

- Combination of return values: `combine_proposals(ζ₁, ζ₂, bias)`,
  `combine_turnstats(τ₁, τ₂)`, and `combine_divstats(d₁, d₂)`
"""
function adjacent_tree(rng, trajectory, z, depth, fwd)
    if depth == 0
        z = move(trajectory, z, fwd)
        ζ, τ, d = leaf(trajectory, z, false)
        ζ, τ, d, z
    else
        ζ₋, τ₋, d₋, z = adjacent_tree(rng, trajectory, z, depth-1, fwd)
        (isdivergent(d₋) || (depth > 1 && isturning(τ₋))) && return ζ₋, τ₋, d₋, z
        ζ₊, τ₊, d₊, z = adjacent_tree(rng, trajectory, z, depth-1, fwd)
        d = combine_divstats(d₋, d₊)
        (isdivergent(d) || (depth > 1 && isturning(τ₊))) && return ζ₊, τ₊, d, z
        τ = fwd ? combine_turnstats(τ₋, τ₊) : combine_turnstats(τ₊, τ₋)
        ζ = isturning(τ) ? nothing : combine_proposals(rng, ζ₋, ζ₊, false)
        ζ, τ, d, z
    end
end

"Reason for terminating a trajectory."
@enum Termination MaxDepth AdjacentDivergent AdjacentTurn DoubledTurn

"""
    ζ, d, termination, depth = sample_trajectory(rng, trajectory, z, max_depth)

Sample a `trajectory` starting at `z`.

Return:

- `ζ`: proposal from the tree

- `d`: divergence statistics

- `termination`: reason for termination (see [`Termination`](@ref))

- `depth`: the depth of the tree that as sampled from. Doubling steps that lead
  to an invalid tree do not contribute to `depth`.

See [`adjacent_tree`](@ref) for the interface that needs to be supported by
`trajectory`.
"""
function sample_trajectory(rng, trajectory, z, max_depth)
    ζ, τ, d = leaf(trajectory, z, true)
    z₋ = z₊ = z
    depth = 0
    termination = MaxDepth
    while depth < max_depth
        fwd = rand_bool(rng, 0.5)
        ζ′, τ′, d′, z = adjacent_tree(rng, trajectory, fwd ? z₊ : z₋, depth, fwd)
        d = combine_divstats(d, d′)
        isdivergent(d) && (termination = AdjacentDivergent; break)
        (depth > 0 && isturning(τ′)) && (termination = AdjacentTurn; break)
        ζ = combine_proposals(rng, ζ, ζ′, true)
        τ = fwd ? combine_turnstats(τ, τ′) : combine_turnstats(τ′, τ)
        fwd ? z₊ = z : z₋ = z
        depth += 1
        isturning(τ) && (termination = DoubledTurn; break)
    end
    ζ, d, termination, depth
end


# proposals

"""
Proposal that is propagated through by sampling recursively when building the
trees.
"""
struct Proposal{Tz,Tf}
    "Proposed point."
    z::Tz
    "Log weight (log(∑ exp(Δ)) of trajectory/subtree)."
    ω::Tf
end

"""
    logprob, ω = combined_logprob_logweight(ω₁, ω₂, bias)

Given (relative) log probabilities `ω₁` and `ω₂`, return the log probabiliy of
drawing a sampel from the second (`logprob`) and the combined (relative) log
probability (`ω`).

When `bias`, biases towards the second argument, introducing anti-correlations.
"""
function combined_logprob_logweight(ω₁, ω₂, bias)
    ω = logsumexp(ω₁, ω₂)
    ω₂ - (bias ? ω₁ : ω), ω
end

"""
    combine_proposals(rng, ζ₁, ζ₂, bias)

Combine proposals from two trajectories, using their weights.

When `bias`, biases towards the second proposal, introducing anti-correlations.
"""
function combine_proposals(rng, ζ₁::Proposal, ζ₂::Proposal, bias)
    logprob, ω = combined_logprob_logweight(ζ₁.ω, ζ₂.ω, bias)
    z = (logprob ≥ 0 || rand_bool(rng, exp(logprob))) ? ζ₂.z : ζ₁.z
    Proposal(z, ω)
end


# divergence statistics

"""
Divergence and acceptance statistics.

Calculated over all visited phase points (not just the tree that is sampled
from).
"""
struct DivergenceStatistic{Tf}
    "`true` iff the sampler was terminated because of divergence."
    divergent::Bool
    "Sum of metropolis acceptances probabilities over the whole trajectory
    (including invalid parts)."
    ∑a::Tf
    "Total number of leapfrog steps."
    steps::Int
end

"""
    divergence_statistic()

Empty divergence statistic (for initial node).
"""
divergence_statistic() = DivergenceStatistic(false, 0.0, 0)

"""
    divergence_statistic(isdivergent, Δ)

Divergence statistic for leaves. `Δ` is the log density relative to the initial
point.
"""
divergence_statistic(isdivergent, Δ) =
    DivergenceStatistic(isdivergent, Δ ≥ 0 ? one(Δ) : exp(Δ), 1)

"""
    isdivergent(x)

Test if divergence statistic `x` indicates divergence.
"""
isdivergent(x::DivergenceStatistic) = x.divergent

"""
    combine_divstats(x, y)

Combine divergence statistics from (subtrees) `x` and `y`. A divergent subtree
make a subtree divergent.
"""
function combine_divstats(x::DivergenceStatistic, y::DivergenceStatistic)
    DivergenceStatistic(x.divergent || y.divergent,
                        x.∑a + y.∑a, x.steps + y.steps)
end

"""
    get_acceptance_rate(x)

Return average Metropolis acceptance rate.
"""
get_acceptance_rate(x::DivergenceStatistic) = x.∑a / x.steps


# turn analysis

"""
Statistics for the identification of turning points. See Betancourt (2017,
appendix).
"""
struct TurnStatistic{T}
    p♯₋::T
    p♯₊::T
    ρ::T
end

"""
    combine_turnstats(x, y)

Combine turn statistics of two trajectories `x` and `y`, which are assume to be
adjacent and in that order.
"""
combine_turnstats(x::TurnStatistic, y::TurnStatistic) =
    TurnStatistic(x.p♯₋, y.p♯₊, x.ρ + y.ρ)

"""
    isturning(τ)

Test termination based on turn statistics. Uses the generalized NUTS criterion
from Betancourt (2017).

Note that this function should not be called with turn statistics returned by
[`leaf`](@ref), ie `depth > 0` is required.
"""
function isturning(τ::TurnStatistic)
    @unpack p♯₋, p♯₊, ρ = τ
    dot(p♯₋, ρ) < 0 || dot(p♯₊, ρ) < 0
end


# sampling

"""
Representation of a trajectory, ie a Hamiltonian with a discrete integrator that
also checks for divergence.
"""
struct Trajectory{TH,Tf}
    "Hamiltonian."
    H::TH
    "Log density of z (negative log energy) at initial point."
    π₀::Tf
    "Stepsize for leapfrog."
    ϵ::Tf
    "Smallest decrease allowed in the log density."
    min_Δ::Tf
end

"""
    Trajectory(H, π₀, ϵ; min_Δ = -1000.0)

Convenience constructor for trajectory.
"""
Trajectory(H, π₀, ϵ; min_Δ = -1000.0) = Trajectory(H, π₀, ϵ, min_Δ)

"""
    ζ, τ, d = leaf(trajectory, z, isinitial)

Construct a proposal, turn statistic, and divergence statistic for a single
point `z` in `trajectory`. When `isinitial`, `z` is the initial point in the
trajectory.

Return

- `ζ`: the proposal, which should only be used when `!isdivergent(d)`

- `τ`: the turn statistic, which should only be used when `!isdivergent(d)`

- `d`: divergence statistic
"""
function leaf(trajectory::Trajectory, z, isinitial)
    @unpack H, π₀, min_Δ = trajectory
    Δ = isinitial ? zero(π₀) : neg_energy(H, z) - π₀
    isdiv = min_Δ > Δ
    d = isinitial ? divergence_statistic() : divergence_statistic(isdiv, Δ)
    ζ = isdiv ? nothing : Proposal(z, Δ)
    τ = isdiv ? nothing : (p♯ = get_p♯(trajectory.H, z); TurnStatistic(p♯, p♯, z.p))
    ζ, τ, d
end

"""
    move(trajectory, z, fwd)

Return next phase point adjacent to `z` along `trajectory` in the direction
specified by `fwd`.
"""
function move(trajectory::Trajectory, z, fwd)
    @unpack H, ϵ = trajectory
    leapfrog(H, z, fwd ? ϵ : -ϵ)
end

"""
Single transition by the No-U-turn sampler. Contains new position and
diagnostic information.
"""
struct NUTS_Transition{Tv,Tf}
    "New position."
    q::Tv
    "Log density (negative energy)."
    π::Tf
    "Depth of the tree."
    depth::Int
    "Reason for termination."
    termination::Termination
    "Average acceptance probability."
    a::Tf
    "Number of leapfrog steps evaluated."
    steps::Int
end

"Position after transition."
get_position(x::NUTS_Transition) = x.q

"Negative energy of the Hamiltonian at the position."
get_neg_energy(x::NUTS_Transition) = x.π

"Tree depth."
get_depth(x::NUTS_Transition) = x.depth

"Reason for termination, see [`Termination`](@ref)."
get_termination(x::NUTS_Transition) = x.termination

"Average acceptance rate over trajectory."
get_acceptance_rate(x::NUTS_Transition) = x.a

"Number of integrator steps."
get_steps(x::NUTS_Transition) = x.steps

"""
    NUTS_transition(rng, H, q, ϵ, max_depth; args...)

No-U-turn Hamiltonian Monte Carlo transition, using Hamiltonian `H`, starting at
position `q`, using stepsize `ϵ`. Builds a doubling dynamic tree of maximum
depth `max_depth`. `args` are passed to the `Trajectory` constructor. `rng` is
the random number generator used.
"""
function NUTS_transition(rng, H, q, ϵ, max_depth; args...)
    z = rand_phasepoint(rng, H, q)
    trajectory = Trajectory(H, neg_energy(H, z), ϵ; args...)
    ζ, d, termination, depth = sample_trajectory(rng, trajectory, z, max_depth)
    NUTS_Transition(ζ.z.q, neg_energy(H, ζ.z), depth, termination,
                    get_acceptance_rate(d), d.steps)
end


# high-level interface: sampler

"""
Specification for the No-U-turn algorithm, including the random number
generator, Hamiltonian, the initial position, and various parameters.
"""
struct NUTS{Tv, Tf, TR, TH}
    "Random number generator."
    rng::TR
    "Hamiltonian"
    H::TH
    "position"
    q::Tv
    "stepsize"
    ϵ::Tf
    "maximum depth of the tree"
    max_depth::Int
end

function show(io::IO, nuts::NUTS)
    @unpack q, ϵ, max_depth = nuts
    println(io, "NUTS sampler in $(length(q)) dimensions")
    println(io, "  stepsize (ϵ) ≈ $(signif(ϵ, 3))")
    println(io, "  maximum depth = $(max_depth)")
    println(io, "  $(nuts.H.κ)")
end

"""
    mcmc(sampler, N)

Run the MCMC `sampler` for `N` iterations, returning the results as a vector,
which has elements that conform to the sampler.
"""
function mcmc(sampler::NUTS{Tv,Tf}, N::Int) where {Tv,Tf}
    @unpack rng, H, q, ϵ, max_depth = sampler
    sample = Vector{NUTS_Transition{Tv,Tf}}(N)
    for i in 1:N
        trans = NUTS_transition(rng, H, q, ϵ, max_depth)
        q = trans.q
        sample[i] .= trans
    end
    sample
end

"""
    sample, A = mcmc_adapting_ϵ(rng, sampler, N, [A_params, A])

Same as [`mcmc`](@ref), but [`tune`](@ref) stepsize ϵ according to the
parameters `A_params` and initial state `A`. Return the updated `A` as the
second value.

When the last two parameters are not specified, initialize using `adapting_ϵ`.
"""
function mcmc_adapting_ϵ(sampler::NUTS{Tv,Tf}, N::Int, A_params, A) where {Tv,Tf}
    @unpack rng, H, q, max_depth = sampler
    sample = Vector{NUTS_Transition{Tv,Tf}}(N)
    for i in 1:N
        trans = NUTS_transition(rng, H, q, get_ϵ(A), max_depth)
        A = adapt_stepsize(A_params, A, trans.a)
        q = trans.q
        sample[i] .= trans
    end
    sample, A
end

mcmc_adapting_ϵ(sampler::NUTS, N) =
    mcmc_adapting_ϵ(sampler, N, adapting_ϵ(sampler.ϵ)...)

"""
    variable_matrix(posterior)

Return the samples of the parameter vector as rows of a matrix.
"""
get_position_matrix(sample) = vcat(get_position.(sample)'...)


# tuning and diagnostics


"""
    sample_cov(sample)

Covariance matrix of the sample.
"""
sample_cov(sample) = cov(get_position_matrix(sample), 1)

"""
    EBFMI(sample)

Energy Bayesian fraction of missing information. Useful for diagnosing poorly
chosen kinetic energies.

Low values (`≤ 0.3`) are considered problematic. See Betancourt (2016).
"""
EBFMI(sample) = (πs = get_neg_energy.(sample); mean(abs2, diff(πs)) / var(πs))

"""
    NUTS_init(rng, ℓ, q; κ = GaussianKE(length(q)), p, max_depth, ϵ)

Initialize a NUTS sampler for log density `ℓ` using local information.

# Arguments

- `rng`: the random number generator

- `ℓ`: the likelihood function, should return a type that supports
  `DiffResults.value` and `DiffResults.gradient`

- `q`: initial position.

- `κ`: kinetic energy specification. *Default*: Gaussian with identity matrix.

- `p`: initial momentum. *Default*: random from standard multivariate normal.

- `max_depth`: maximum tree depth. *Default*: `5`.

- `ϵ`: initial stepsize, or parameters for finding it (passed on to
  [`find_initial_stepsize`](@ref).
"""
function NUTS_init(rng, ℓ, q;
                   κ = GaussianKE(length(q)),
                   p = rand(rng, κ),
                   max_depth = 5,
                   ϵ = InitialStepsizeSearch())
    H = Hamiltonian(ℓ, κ)
    z = phasepoint_in(H, q, p)
    if !(ϵ isa Float64)
        ϵ = find_initial_stepsize(ϵ, H, z)
    end
    NUTS(rng, H, q, ϵ, max_depth)
end

"""
    NUTS_init(rng, ℓ, dim::Integer; args...)

Random initialization with position `randn(dim)`, all other arguments are passed
on the the other method of this function.
"""
NUTS_init(rng, ℓ, dim::Integer; args...) = NUTS_init(rng, ℓ, randn(dim); args...)


# tuning: abstract interface

"""
A tuner that adapts the sampler.

All subtypes support `length` which returns the number of steps (*note*: if not
in field `N`, define `length` accordingly), other parameters vary.
"""
abstract type AbstractTuner end

length(tuner::AbstractTuner) = tuner.N

"""
    sampler′ = tune(sampler, tune)

Given a `sampler` (or similar a parametrization) and a `tuner`, return the
updated sampler state after tuning.
"""
function tune end


# tuning: tuner building blocks

"Adapt the integrator stepsize for `N` samples."
struct StepsizeTuner <: AbstractTuner
    N::Int
end

show(io::IO, tuner::StepsizeTuner) =
    print(io, "Stepsize tuner, $(tuner.N) samples")

function tune(sampler::NUTS, tuner::StepsizeTuner)
    @unpack rng, H, max_depth = sampler
    sample, A = mcmc_adapting_ϵ(sampler, tuner.N)
    NUTS(rng, H, sample[end].q, get_ϵ(A, false), max_depth)
end

"""
Tune the integrator stepsize and covariance. Covariance tuning is from scratch
(no prior information is used), regularized towards the identity matrix.
"""
struct StepsizeCovTuner{Tf} <: AbstractTuner
    "Number of samples."
    N::Int
    """
    Regularization factor for normalizing variance. An estimated covariance
    matrix `Σ` is rescaled by `regularize/sample size`` towards `σ²I`, where
    `σ²` is the median of the diagonal.
    """
    regularize::Tf
end

function show(io::IO, tuner::StepsizeCovTuner)
    @unpack N, regularize = tuner
    print(io, "Stepsize and covariance tuner, $(N) samples, regularization $(regularize)")
end

function tune(sampler::NUTS, tuner::StepsizeCovTuner)
    @unpack regularize, N = tuner
    @unpack rng, H, max_depth = sampler
    sample, A = mcmc_adapting_ϵ(sampler, N)
    Σ = sample_cov(sample)
    Σ .+= (UniformScaling(median(diag(Σ)))-Σ) * regularize/N
    κ = GaussianKE(Σ)
    NUTS(rng, Hamiltonian(H.ℓ, κ), sample[end].q, get_ϵ(A), max_depth)
end

"Sequence of tuners, applied in the given order."
struct TunerSequence{T} <: AbstractTuner
    tuners::T
end

function show(io::IO, tuner::TunerSequence)
    @unpack tuners = tuner
    print(io, "Sequence of $(length(tuners)) tuners, $(length(tuner)) total samples")
    for t in tuners
        print(io, "\n  ")
        show(io, t)
    end
end

length(seq::TunerSequence) = sum(length, seq.tuners)

"""
    bracketed_doubling_tuner(; [init], [mid], [M], [term], [regularize])

A sequence of tuners:

1. tuning stepsize with `init` steps

2. tuning stepsize and covariance: first with `mid` steps, then repeat with
   twice the steps `M` times

3. tuning stepsize with `term` steps

`regularize` is used for covariance regularization.
"""
function bracketed_doubling_tuner(; init = 75, mid = 25, M = 5, term = 50,
                                  regularize = 5.0, _...)
    tuners = Union{StepsizeTuner, StepsizeCovTuner}[StepsizeTuner(init)]
    for _ in 1:M
        tuners = push!(tuners, StepsizeCovTuner(mid, regularize))
        mid *= 2
    end
    push!(tuners, StepsizeTuner(term))
    TunerSequence((tuners...))
end

function tune(sampler, seq::TunerSequence)
    for tuner in seq.tuners
        sampler = tune(sampler, tuner)
    end
    sampler
end

"""
    $SIGNATURES

Init, tune, and then draw `N` samples from `ℓ` using the NUTS algorithm.

Return the *sample* (a vector of [`NUTS_transition`](@ref)s) and the *tuned
sampler*.

`rng` is the random number generator.

`q_or_dim` is a starting position or the dimension (for random initialization).

`args` are passed on to various methods, see [`NUTS_init`](@ref) and
[`bracketed_doubling_tuner`](@ref).

For parameters `q`, `ℓ(q)` should return an object that support the following
methods: `DiffResults.value`, `DiffResults.gradient`.

Most users would use this function, unless they are doing something that
requires manual tuning.
"""
function NUTS_init_tune_mcmc(rng, ℓ, q_or_dim, N::Int; args...)
    sampler_init = NUTS_init(rng, ℓ, q_or_dim; args...)
    sampler_tuned = tune(sampler_init, bracketed_doubling_tuner(; args...))
    mcmc(sampler_tuned, N), sampler_tuned
end

"""
    $SIGNATURES

Same as the other method, but with random number generator
`Base.Random.GLOBAL_RNG`.
"""
NUTS_init_tune_mcmc(ℓ, q_or_dim, N::Int; args...) =
    NUTS_init_tune_mcmc(Base.Random.GLOBAL_RNG, ℓ, q_or_dim, N; args...)


# statistics and diagnostics

"Acceptance quantiles for [`NUTS_Statistics`](@ref) diagnostic summary."
const ACCEPTANCE_QUANTILES = linspace(0, 1, 5)

"""
Storing the output of [`NUTS_statistics`](@ref) in a structured way, for pretty
printing. Currently for internal use.
"""
struct NUTS_Statistics{T <: Real,
                       DT <: Associative{Termination,Int},
                       DD <: Associative{Int,Int}}
    "Sample length."
    N::Int
    "average_acceptance"
    a_mean::T
    "acceptance quantiles"
    a_quantiles::Vector{T}
    "termination counts"
    termination_counts::DT
    "depth counts"
    depth_counts::DD
end

"""
    NUTS_statistics(sample)

Return statistics about the sample (ie not the variables). Mostly useful for
NUTS diagnostics.
"""
function NUTS_statistics(sample)
    as = get_acceptance_rate.(sample)
    NUTS_Statistics(length(sample),
                    mean(as), quantile(as, ACCEPTANCE_QUANTILES),
                    counter(get_termination.(sample)), counter(get_depth.(sample)))
end

function show(io::IO, stats::NUTS_Statistics)
    @unpack N, a_mean, a_quantiles, termination_counts, depth_counts = stats
    println(io, "Hamiltonian Monte Carlo sample of length $(N)")
    print(io, "  acceptance rate mean: $(round(a_mean,2)), min/25%/median/75%/max:")
    for aq in a_quantiles
        print(io, " ", round(aq, 2))
    end
    println(io)
    function print_dict(dict)
        for (key, value) in sort(collect(dict), by = first)
            print(io, " $(key) => $(round(Int, 100*value/N))%")
        end
    end
    print(io, "  termination:")
    print_dict(termination_counts)
    println(io)
    print(io, "  depth:")
    print_dict(depth_counts)
    println(io)
end

end # module
