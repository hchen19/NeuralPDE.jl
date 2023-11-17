mutable struct PDELogTargetDensity{
    ST <: AbstractTrainingStrategy,
    D <: Union{Vector{Nothing}, Vector{<:Vector{<:AbstractFloat}}},
    P <: Vector{<:Distribution},
    I,
    F,
    PH,
}
    dim::Int64
    strategy::ST
    dataset::D
    priors::P
    allstd::Vector{Vector{Float64}}
    names::Tuple
    physdt::Float64
    extraparams::Int
    init_params::I
    full_loglikelihood::F
    Phi::PH

    function PDELogTargetDensity(dim, strategy, dataset,
            priors, allstd, names, physdt, extraparams,
            init_params::AbstractVector, full_loglikelihood, Phi)
        new{
            typeof(strategy),
            typeof(dataset),
            typeof(priors),
            typeof(init_params),
            typeof(full_loglikelihood),
            typeof(Phi),
        }(dim,
            strategy,
            dataset,
            priors,
            allstd,
            names,
            physdt,
            extraparams,
            init_params,
            full_loglikelihood,
            Phi)
    end
    function PDELogTargetDensity(dim, strategy, dataset,
            priors, allstd, names, physdt, extraparams,
            init_params::NamedTuple, full_loglikelihood, Phi)
        new{
            typeof(strategy),
            typeof(dataset),
            typeof(priors),
            typeof(init_params),
            typeof(full_loglikelihood),
            typeof(Phi),
        }(dim,
            strategy,
            dataset,
            priors,
            allstd,
            names,
            physdt,
            extraparams,
            init_params,
            full_loglikelihood,
            Phi)
    end
end

function LogDensityProblems.logdensity(Tar::PDELogTargetDensity, θ)
    # for parameter estimation neccesarry to use multioutput case
    return Tar.full_loglikelihood(setparameters(Tar, θ),
               Tar.allstd) + priorlogpdf(Tar, θ) + L2LossData(Tar, θ)
    # + L2loss2(Tar, θ)
end

function L2loss2(Tar::PDELogTargetDensity, θ)
    return Tar.full_loglikelihood(setparameters(Tar, θ),
        Tar.allstd)
end
function setparameters(Tar::PDELogTargetDensity, θ)
    names = Tar.names
    ps_new = θ[1:(end - Tar.extraparams)]
    ps = Tar.init_params

    if (ps[names[1]] isa ComponentArrays.ComponentVector)
        # multioutput case for Lux chains, for each depvar ps would contain Lux ComponentVectors
        # which we use for mapping current ahmc sampled vector of parameters onto NNs
        i = 0
        Luxparams = []
        for x in names
            endind = length(ps[x])
            push!(Luxparams, vector_to_parameters(ps_new[(i + 1):(i + endind)], ps[x]))
            i += endind
        end
        Luxparams
    else
        # multioutput Flux
        Luxparams = θ
    end

    if (Luxparams isa AbstractVector) && (Luxparams[1] isa ComponentArrays.ComponentVector)
        # multioutput Lux
        a = ComponentArrays.ComponentArray(NamedTuple{Tar.names}(i for i in Luxparams))

        if Tar.extraparams > 0
            b = θ[(end - Tar.extraparams + 1):end]

            return ComponentArrays.ComponentArray(;
                depvar = a,
                p = b)
        else
            return ComponentArrays.ComponentArray(;
                depvar = a)
        end
    else
        # multioutput Lux case
        return vector_to_parameters(Luxparams, ps)
    end
end

LogDensityProblems.dimension(Tar::PDELogTargetDensity) = Tar.dim

function LogDensityProblems.capabilities(::PDELogTargetDensity)
    LogDensityProblems.LogDensityOrder{1}()
end

function L2loss2(Tar::PDELogTargetDensity, θ)
    return logpdf(MvNormal(pde(phi, Tar.dataset[end], θ)), zeros(length(pde_eqs)))
end
# L2 losses loglikelihood(needed mainly for ODE parameter estimation)
function L2LossData(Tar::PDELogTargetDensity, θ)
    if Tar.extraparams > 0
        if Tar.init_params isa ComponentArrays.ComponentVector
            return sum([logpdf(MvNormal(Tar.Phi[i](Tar.dataset[end]',
                        vector_to_parameters(θ[1:(end - Tar.extraparams)],
                            Tar.init_params)[Tar.names[i]])[1,
                        :], ones(length(Tar.dataset[end])) .* Tar.allstd[3][i]), Tar.dataset[i])
                        for i in eachindex(Tar.Phi)])
        else
            # Flux case needs subindexing wrt Tar.names indices(hence stored in Tar.names)
            return sum([logpdf(MvNormal(Tar.Phi[i](Tar.dataset[end]',
                        vector_to_parameters(θ[1:(end - Tar.extraparams)],
                            Tar.init_params)[Tar.names[2][i]])[1,
                        :], ones(length(Tar.dataset[end])) .* Tar.allstd[3][i]), Tar.dataset[i])
                        for i in eachindex(Tar.Phi)])
        end
    else
        return 0
    end
end

# priors for NN parameters + ODE constants
function priorlogpdf(Tar::PDELogTargetDensity, θ)
    allparams = Tar.priors
    # Vector of ode parameters priors
    invpriors = allparams[2:end]

    # nn weights
    nnwparams = allparams[1]

    if Tar.extraparams > 0
        invlogpdf = sum(logpdf(invpriors[length(θ) - i + 1], θ[i])
                        for i in (length(θ) - Tar.extraparams + 1):length(θ); init = 0.0)

        return (invlogpdf
                +
                logpdf(nnwparams, θ[1:(length(θ) - Tar.extraparams)]))
    else
        return logpdf(nnwparams, θ)
    end
end

function kernelchoice(Kernel, MCMCkwargs)
    if Kernel == HMCDA
        δ, λ = MCMCkwargs[:δ], MCMCkwargs[:λ]
        Kernel(δ, λ)
    elseif Kernel == NUTS
        δ, max_depth, Δ_max = MCMCkwargs[:δ], MCMCkwargs[:max_depth], MCMCkwargs[:Δ_max]
        Kernel(δ, max_depth = max_depth, Δ_max = Δ_max)
    else
        # HMC
        n_leapfrog = MCMCkwargs[:n_leapfrog]
        Kernel(n_leapfrog)
    end
end

function integratorchoice(Integratorkwargs, initial_ϵ)
    Integrator = Integratorkwargs[:Integrator]
    if Integrator == JitteredLeapfrog
        jitter_rate = Integratorkwargs[:jitter_rate]
        Integrator(initial_ϵ, jitter_rate)
    elseif Integrator == TemperedLeapfrog
        tempering_rate = Integratorkwargs[:tempering_rate]
        Integrator(initial_ϵ, tempering_rate)
    else
        Integrator(initial_ϵ)
    end
end

function adaptorchoice(Adaptor, mma, ssa)
    if Adaptor != AdvancedHMC.NoAdaptation()
        Adaptor(mma, ssa)
    else
        AdvancedHMC.NoAdaptation()
    end
end

# dataset would be (x̂,t)
# priors: pdf for W,b + pdf for ODE params
# lotka specific kwargs here
function ahmc_bayesian_pinn_pde(pde_system, discretization;
        strategy = GridTraining, dataset = [nothing],
        init_params = nothing, draw_samples = 1000,
        physdt = 1 / 20.0, bcstd = [0.01], l2std = [0.05],
        phystd = [0.05], priorsNNw = (0.0, 2.0),
        param = [], nchains = 1, Kernel = HMC,
        Adaptorkwargs = (Adaptor = StanHMCAdaptor,
            Metric = DiagEuclideanMetric, targetacceptancerate = 0.8),
        Integratorkwargs = (Integrator = Leapfrog,),
        MCMCkwargs = (n_leapfrog = 30,),
        progress = false, verbose = false)
    pinnrep = symbolic_discretize(pde_system, discretization, bayesian = true)

    # for physics loglikelihood
    full_weighted_loglikelihood = pinnrep.loss_functions.full_loss_function
    chain = discretization.chain

    # NN solutions for loglikelihood which is used for L2lossdata
    Phi = pinnrep.phi

    # for new L2 loss
    # discretization.additional_loss = 

    if nchains > Threads.nthreads()
        throw(error("number of chains is greater than available threads"))
    elseif nchains < 1
        throw(error("number of chains must be greater than 1"))
    end

    # remove inv params take only NN params, AHMC uses Float64
    initial_nnθ = pinnrep.flat_init_params[1:(end - length(param))]
    initial_θ = collect(Float64, initial_nnθ)
    initial_nnθ = pinnrep.init_params

    if (discretization.multioutput && chain[1] isa Lux.AbstractExplicitLayer)
        # converting vector of parameters to ComponentArray for runtimegenerated functions
        names = ntuple(i -> pinnrep.depvars[i], length(chain))
    else
        # this case is for Flux multioutput
        i = 0
        temp = []
        for j in eachindex(initial_nnθ)
            len = length(initial_nnθ[j])
            push!(temp, (i + 1):(i + len))
            i += len
        end
        names = tuple(1, temp)
    end

    #ode parameter estimation
    nparameters = length(initial_θ)
    ninv = length(param)
    priors = [MvNormal(priorsNNw[1] * ones(nparameters), priorsNNw[2] * ones(nparameters))]

    # append Ode params to all paramvector - initial_θ
    if ninv > 0
        # shift ode params(initialise ode params by prior means)
        # check if means or user speified is better
        initial_θ = vcat(initial_θ, [Distributions.params(param[i])[1] for i in 1:ninv])
        priors = vcat(priors, param)
        nparameters += ninv
    end

    strategy = strategy(physdt)

    # dimensions would be total no of params,initial_nnθ for Lux namedTuples 
    ℓπ = PDELogTargetDensity(nparameters,
        strategy,
        dataset,
        priors,
        [phystd, bcstd, l2std],
        names,
        physdt,
        ninv,
        initial_nnθ,
        full_weighted_loglikelihood,
        Phi)

    Adaptor, Metric, targetacceptancerate = Adaptorkwargs[:Adaptor],
    Adaptorkwargs[:Metric], Adaptorkwargs[:targetacceptancerate]

    # Define Hamiltonian system (nparameters ~ dimensionality of the sampling space)
    metric = Metric(nparameters)
    hamiltonian = Hamiltonian(metric, ℓπ, ForwardDiff)

    # parallel sampling option
    if nchains != 1
        # Cache to store the chains
        chains = Vector{Any}(undef, nchains)
        statsc = Vector{Any}(undef, nchains)
        samplesc = Vector{Any}(undef, nchains)

        Threads.@threads for i in 1:nchains
            # each chain has different initial NNparameter values(better posterior exploration)
            initial_θ = vcat(randn(nparameters - ninv),
                initial_θ[(nparameters - ninv + 1):end])
            initial_ϵ = find_good_stepsize(hamiltonian, initial_θ)
            integrator = integratorchoice(Integratorkwargs, initial_ϵ)
            adaptor = adaptorchoice(Adaptor, MassMatrixAdaptor(metric),
                StepSizeAdaptor(targetacceptancerate, integrator))

            MCMC_alg = kernelchoice(Kernel, MCMCkwargs)
            Kernel = AdvancedHMC.make_kernel(MCMC_alg, integrator)
            samples, stats = sample(hamiltonian, Kernel, initial_θ, draw_samples, adaptor;
                progress = progress, verbose = verbose)

            samplesc[i] = samples
            statsc[i] = stats
            mcmc_chain = Chains(hcat(samples...)')
            chains[i] = mcmc_chain
        end

        return chains, samplesc, statsc
    else
        initial_ϵ = find_good_stepsize(hamiltonian, initial_θ)
        integrator = integratorchoice(Integratorkwargs, initial_ϵ)
        adaptor = adaptorchoice(Adaptor, MassMatrixAdaptor(metric),
            StepSizeAdaptor(targetacceptancerate, integrator))

        MCMC_alg = kernelchoice(Kernel, MCMCkwargs)
        Kernel = AdvancedHMC.make_kernel(MCMC_alg, integrator)
        samples, stats = sample(hamiltonian, Kernel, initial_θ, draw_samples,
            adaptor; progress = progress, verbose = verbose)

        # return a chain(basic chain),samples and stats
        matrix_samples = hcat(samples...)
        mcmc_chain = MCMCChains.Chains(matrix_samples')
        return mcmc_chain, samples, stats
    end
end