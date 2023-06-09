## GPT3ISFullChoiceMap ##

"""
    GPT3ISFullChoiceMap

An alias for the static choice map associated with a [`GPT3ISTrace`](@ref).
"""
const GPT3ISFullChoiceMap =
    Gen.StaticChoiceMap{(OUTPUT_ADDR, :chosen), Tuple{String, Int}, (), Tuple{}}

"""
    GPT3ISOutputChoiceMap

Static choicemap alias. Contains the output of a [`GPT3ISTrace`](@ref).
"""
const GPT3ISOutputChoiceMap = GPT3ChoiceMap

"""
    GPT3ISChosenChoiceMap

Static choicemap alias. Contains the chosen index of a [`GPT3ISTrace`](@ref).
"""
const GPT3ISChosenChoiceMap =
    Gen.StaticChoiceMap{(:chosen), Tuple{Int}, (), Tuple{}}

"""
    GPT3ISValidChosenChoiceMap

Static choicemap alias. Contains the chosen index of a [`GPT3ISTrace`](@ref)
among all valid choices, corresponding to the address `:valid_chosen`.
"""
const GPT3ISValidChosenChoiceMap =
    Gen.StaticChoiceMap{(:valid_chosen), Tuple{Int}, (), Tuple{}}


"""
    GPT3ISChosenRegenChoiceMap

Static choicemap alias. Contains the chosen index of a [`GPT3ISTrace`](@ref).
When used with `update`, the output is regenerated from the chosen index.
"""
const GPT3ISChosenRegenChoiceMap = 
    Gen.StaticChoiceMap{(OUTPUT_ADDR, :chosen), Tuple{Nothing, Int}, (), Tuple{}}

## GPT3ImportanceSamplerTrace ##

"""
    GPT3ImportanceSamplerTrace

A trace generated by importance sampling from a GPT-3 model using a 
[`GPT3ImportanceSampler`](@ref). Comprised of a (batched) model trace and a 
(batched) proposal trace, each generated from [`MultiGPT3GF`](@ref) generative
functions, potentially with different prompts.
"""
struct GPT3ImportanceSamplerTrace{T <: GenerativeFunction} <: Trace
    gen_fn::T
    n_samples::Int
    model_prompt::String
    proposal_prompt::String
    model_trace::MultiGPT3Trace{MultiGPT3GF}
    proposal_trace::MultiGPT3Trace{MultiGPT3GF}
    valid::BitVector
    log_weights::Vector{Float64}
    log_z_est::Float64
    chosen_idx::Int
    output::String
    tokens::Vector{String}
    logprobs::Vector{Float64}
    model_score::Float64
    score::Float64
end

"""
    GPT3ISTrace

Alias for [`GPT3ImportanceSamplerTrace`](@ref).
"""
const GPT3ISTrace = GPT3ImportanceSamplerTrace

get_retval(trace::GPT3ISTrace) = trace.output
get_score(trace::GPT3ISTrace) = trace.score
get_gen_fn(trace::GPT3ISTrace) = trace.gen_fn
get_args(trace::GPT3ISTrace) = 
    (trace.n_samples, trace.model_prompt, trace.proposal_prompt)

function get_choices(trace::GPT3ISTrace)
    vals = NamedTuple{(OUTPUT_ADDR, :chosen)}((trace.output, trace.chosen_idx))
    return Gen.StaticChoiceMap(vals, NamedTuple(), false)
end

function Base.:(==)(trace1::GPT3ISTrace, trace2::GPT3ISTrace)
    return (trace1.output == trace2.output &&
            trace1.model_prompt == trace2.model_prompt &&
            trace1.proposal_prompt == trace2.proposal_prompt &&
            trace1.model_trace == trace2.model_trace &&
            trace1.proposal_trace == trace2.proposal_trace &&
            trace1.valid == trace2.valid &&
            trace1.log_weights == trace2.log_weights &&
            trace1.log_z_est == trace2.log_z_est &&
            trace1.chosen_idx == trace2.chosen_idx &&
            trace1.output == trace2.output &&
            trace1.tokens == trace2.tokens &&
            trace1.logprobs == trace2.logprobs &&
            trace1.score == trace2.score)
end

## GPT3ImportanceSampler ##

"""
    GPT3ImportanceSampler

A generative function that performs importance sampling from a GPT-3 model
using a [`MultiGPT3GF`](@ref) generative function as both the model and the
proposal. Called with arguments `(n_samples, model_prompt, proposal_prompt)`,
where `n_samples` is the number of samples to draw, `model_prompt` is the prompt
to use for the model, and `proposal_prompt` is the prompt to use for the
proposal.

After `n_samples` samples are drawn from the proposal, the model is used to 
score each sample, and importance weights are computed. A single sample is then
chosen according to the importance weights, which is returned as the output of
the generative function. Both the `output` and `chosen` index are part of the
trace's choicemap.
"""
@kwdef struct GPT3ImportanceSampler{V} <: GenerativeFunction{String,GPT3ISTrace}
    model_gf::MultiGPT3GF = MultiGPT3GF()
    proposal_gf::MultiGPT3GF = model_gf
    validator::V = nothing
    cache_traces::Bool = false
    cache::Dict{Tuple{Int, String, String}, GPT3ISTrace} =
        Dict{Tuple{Int, String, String}, GPT3ISTrace}()
end

"""
    GPT3IS

Alias for [`GPT3ImportanceSampler`](@ref).
"""
const GPT3IS = GPT3ImportanceSampler

# Standard importance sampling
function simulate(gen_fn::GPT3IS{Nothing}, args::Tuple)
    # Extract arguments
    if length(args) == 3
        n_samples, model_prompt, proposal_prompt = args
    elseif length(args) == 2
        n_samples, model_prompt = args
        proposal_prompt = model_prompt
    else
        error("Expected 2 or 3 arguments to GPT3ImportanceSampler")
    end
    # Return cached trace if available
    if gen_fn.cache_traces
        args = (n_samples, model_prompt, proposal_prompt)
        trace = get(gen_fn.cache, args, nothing)
        if !isnothing(trace) # Regenerate chosen index and return trace
            selection = select(:chosen => true, OUTPUT_ADDR => nothing)
            trace, _, _ = regenerate(trace, selection)
            return trace
        end
    end
    # Sample and score completions
    prop_trace = simulate(gen_fn.proposal_gf, (n_samples, proposal_prompt))
    if gen_fn.model_gf === gen_fn.proposal_gf && model_prompt == proposal_prompt
        model_trace = prop_trace
    else
        prop_choices = get_choices(prop_trace)
        model_trace, _ =
            generate(gen_fn.model_gf, (n_samples, model_prompt), prop_choices)
    end
    # Compute importance weights and normalizing constant
    valid = trues(n_samples)
    log_weights = model_trace.scores .- prop_trace.scores
    log_sum_weights = logsumexp(log_weights)
    log_z_est = log_sum_weights - log(n_samples)
    # Resample according to importance weights
    chosen_idx = randboltzmann(1:n_samples, log_weights)
    # Select output etc. from model trace
    output = model_trace.outputs[chosen_idx]
    tokens = model_trace.tokens[chosen_idx]
    logprobs = model_trace.logprobs[chosen_idx]
    model_score = model_trace.scores[chosen_idx]
    # Compute score and construct trace
    score = model_score - log_sum_weights
    trace = GPT3ISTrace(
        gen_fn, n_samples, model_prompt, proposal_prompt,
        model_trace, prop_trace, valid, log_weights, log_z_est,
        chosen_idx, output, tokens, logprobs, model_score, score
    )
    # Store trace in cache
    if gen_fn.cache_traces
        gen_fn.cache[args] = trace
    end
    return trace
end

# Alive importance sampling
function simulate(gen_fn::GPT3IS, args::Tuple)
    # Extract arguments
    if length(args) == 3
        n_samples, model_prompt, proposal_prompt = args
    elseif length(args) == 2
        n_samples, model_prompt = args
        proposal_prompt = model_prompt
    else
        error("Expected 2 or 3 arguments to GPT3ImportanceSampler")
    end
    # Return cached trace if available
    if gen_fn.cache_traces
        args = (n_samples, model_prompt, proposal_prompt)
        trace = get(gen_fn.cache, args, nothing)
        if !isnothing(trace) # Regenerate chosen index and return trace
            selection = select(:chosen => true, OUTPUT_ADDR => nothing)
            trace, _, _ = regenerate(trace, selection)
            return trace
        end
    end
    # Sample and validate completions until we reach `n_samples + 1`
    prop_trace = MultiGPT3Trace(gen_fn.proposal_gf)
    valid = falses(0)
    n_remain, n_trials = (n_samples + 1), 0
    while n_remain > 0
        new_trace = simulate(gen_fn.proposal_gf, (n_remain, proposal_prompt))
        prop_trace = vcat(prop_trace, new_trace)
        new_valid = gen_fn.validator.(new_trace.outputs)
        valid = append!(valid, new_valid)
        n_trials += n_remain
        n_remain -= sum(new_valid)
    end
    # Score completions under model
    if gen_fn.model_gf === gen_fn.proposal_gf && model_prompt == proposal_prompt
        model_trace = prop_trace
    else
        prop_choices = get_choices(prop_trace)
        model_trace, _ =
            generate(gen_fn.model_gf, (n_trials, model_prompt), prop_choices)
    end
    # Compute importance weights and normalizing constant
    log_weights = model_trace.scores .- prop_trace.scores
    valid_log_weights = resize!(log_weights .* valid, n_trials - 1)
    log_sum_weights = logsumexp(valid_log_weights)
    log_z_est = log_sum_weights - log(n_trials - 1)
    # Resample according to importance weights
    chosen_idx = randboltzmann(1:(n_trials-1), valid_log_weights)
    # Select output etc. from model trace
    output = model_trace.outputs[chosen_idx]
    tokens = model_trace.tokens[chosen_idx]
    logprobs = model_trace.logprobs[chosen_idx]
    model_score = model_trace.scores[chosen_idx]
    # Compute score and construct trace
    score = model_score - log_sum_weights
    trace = GPT3ISTrace(
        gen_fn, n_samples, model_prompt, proposal_prompt,
        model_trace, prop_trace, valid, log_weights, log_z_est,
        chosen_idx, output, tokens, logprobs, model_score, score
    )
    # Store trace in cache
    if gen_fn.cache_traces
        gen_fn.cache[args] = trace
    end
    return trace
end

function generate(gen_fn::GPT3IS, args::Tuple, constraints::ChoiceMap)
    # Dispatch to `generate` implementations for specific constraints
    if isempty(constraints)
        return generate(gen_fn, args, EmptyChoiceMap())
    end
    return generate(gen_fn, args, StaticChoiceMap(constraints))
end

# Chosen index is constrained
function generate(gen_fn::GPT3IS, args::Tuple, constraints::GPT3ISChosenChoiceMap)
    # Extract arguments
    if length(args) == 3
        n_samples, model_prompt, proposal_prompt = args
    elseif length(args) == 2
        n_samples, model_prompt = args
        proposal_prompt = model_prompt
    else
        error("Expected 2 or 3 arguments to GPT3ImportanceSampler")
    end
    # Run unconditional SIR, then select index
    if gen_fn.cache_traces
        args = (n_samples, model_prompt, proposal_prompt)
        trace = get(gen_fn.cache, args) do 
            simulate(gen_fn, args)
        end
    else
        trace = simulate(gen_fn, args)
    end
    # Select output etc. from model trace
    chosen_idx = get_value(constraints, :chosen)
    output = trace.model_trace.outputs[chosen_idx]
    tokens = trace.model_trace.tokens[chosen_idx]
    logprobs = trace.model_trace.logprobs[chosen_idx]
    model_score = trace.model_trace.scores[chosen_idx]
    if isnothing(gen_fn.validator)
        is_valid = trace.valid[chosen_idx]
    else # Alive importance sampling forbids sampling final completion
        is_valid = trace.valid[chosen_idx] && chosen_idx < length(trace.valid)
    end
    # Compute score and construct trace
    score = is_valid ? model_score - trace.log_z_est : -Inf
    new_trace = GPT3ISTrace(
        trace.gen_fn, trace.n_samples,
        trace.model_prompt, trace.proposal_prompt,
        trace.model_trace, trace.proposal_trace, trace.valid,
        trace.log_weights, trace.log_z_est,
        chosen_idx, output, tokens, logprobs, model_score, score
    )
    # Compute weight for generate
    if !is_valid
        return new_trace, -Inf
    elseif isnothing(gen_fn.validator) # Standard importance sampling
        log_sum_weights = trace.log_z_est + log(trace.n_samples)
    else # Alive importance sampling
        log_sum_weights = trace.log_z_est + log(length(trace.valid) - 1)
    end
    weight = trace.log_weights[chosen_idx] - log_sum_weights
    return new_trace, weight
end

# Valid chosen index is constrained
function generate(gen_fn::GPT3IS, args::Tuple,
                  constraints::GPT3ISValidChosenChoiceMap)
    # Extract arguments
    if length(args) == 3
        n_samples, model_prompt, proposal_prompt = args
    elseif length(args) == 2
        n_samples, model_prompt = args
        proposal_prompt = model_prompt
    else
        error("Expected 2 or 3 arguments to GPT3ImportanceSampler")
    end
    # Run unconditional SIR, then select index
    if gen_fn.cache_traces
        args = (n_samples, model_prompt, proposal_prompt)
        trace = get(gen_fn.cache, args) do 
            simulate(gen_fn, args)
        end
    else
        trace = simulate(gen_fn, args)
    end
    # Determine chosen index
    valid_chosen_idx = get_value(constraints, :valid_chosen)
    @assert 1 <= valid_chosen_idx <= trace.n_samples
    chosen_idx = findall(trace.valid)[valid_chosen_idx]
    # Select output etc. from model trace
    output = trace.model_trace.outputs[chosen_idx]
    tokens = trace.model_trace.tokens[chosen_idx]
    logprobs = trace.model_trace.logprobs[chosen_idx]
    model_score = trace.model_trace.scores[chosen_idx]
    # Compute score and construct trace
    score = model_score - trace.log_z_est
    new_trace = GPT3ISTrace(
        trace.gen_fn, trace.n_samples,
        trace.model_prompt, trace.proposal_prompt,
        trace.model_trace, trace.proposal_trace, trace.valid,
        trace.log_weights, trace.log_z_est,
        chosen_idx, output, tokens, logprobs, model_score, score
    )
    # Compute weight for generate
    if isnothing(gen_fn.validator) # Standard importance sampling
        log_sum_weights = trace.log_z_est + log(trace.n_samples)
    else # Alive importance sampling
        log_sum_weights = trace.log_z_est + log(length(trace.valid) - 1)
    end
    weight = trace.log_weights[chosen_idx] - log_sum_weights
    return new_trace, weight
end

# Nothing is constrained
generate(gen_fn::GPT3IS, args::Tuple, ::EmptyChoiceMap) =
    simulate(gen_fn, args), 0.0

generate(gen_fn::GPT3IS, args::Tuple, ::StaticSelection) =
    error("`generate`` not implemented for this set of constraints.")

function project(trace::GPT3ISTrace, selection::Selection)
    if OUTPUT_ADDR in selection && !(:chosen in selection)
        return trace.model_score - trace.log_z_est
    elseif :chosen in selection && !(OUTPUT_ADDR in selection)
        chosen_weight = trace.log_weights[trace.chosen_idx]
        if isnothing(trace.gen_fn.validator) # Standard importance sampling
            log_sum_weights = trace.log_z_est + log(trace.n_samples)
        else # Alive importance sampling
            log_sum_weights = trace.log_z_est + log(length(trace.valid) - 1)
        end
        return chosen_weight - log_sum_weights
    elseif OUTPUT_ADDR in selection && :chosen in selection
        return trace.score
    else
        return 0.0
    end
end

project(trace::GPT3ISTrace, selection::AllSelection) = trace.score

project(trace::GPT3ISTrace, selection::EmptySelection) = 0.0

function update(trace::GPT3ISTrace, args::Tuple, argdiffs::Tuple,
                constraints::ChoiceMap)
    # Compute argdiffs
    if get_args(trace) == args
        argdiffs = (NoChange(), NoChange(), NoChange())
    end    
    # Dispatch to `update` implementations for specific constraints
    if isempty(constraints)
        return update(trace, args, argdiffs, EmptyChoiceMap())
    end
    if argdiffs isa NTuple{3, NoChange}
        return update(trace, args, argdiffs, StaticChoiceMap(constraints))
    end
    # Default to calling `generate`
    new_trace, _ = generate(trace.gen_fn, args, constraints)
    up_weight = get_score(new_trace) - get_score(trace)
    discard = choicemap()
    for (key, val) in get_values_shallow(constraints)
        if key in (OUTPUT_ADDR, :chosen)
            discard[key] = val
        end
    end
    return new_trace, up_weight, UnknownChange(), discard
end

# Chosen index is updated, output is regenerated accordingly
function update(trace::GPT3ISTrace, args::Tuple, ::NTuple{3, NoChange},
                constraints::GPT3ISChosenRegenChoiceMap)
    # Select output etc. from model trace
    chosen_idx = get_value(constraints, :chosen)
    output = trace.model_trace.outputs[chosen_idx]
    tokens = trace.model_trace.tokens[chosen_idx]
    logprobs = trace.model_trace.logprobs[chosen_idx]
    model_score = trace.model_trace.scores[chosen_idx]
    if isnothing(trace.gen_fn.validator)
        is_valid = trace.valid[chosen_idx]
    else # Alive importance sampling forbids sampling final completion
        is_valid = trace.valid[chosen_idx] && chosen_idx < length(trace.valid)
    end
    # Compute score and construct trace
    score = is_valid ? model_score - trace.log_z_est : -Inf
    new_trace = GPT3ISTrace(
        trace.gen_fn, trace.n_samples,
        trace.model_prompt, trace.proposal_prompt,
        trace.model_trace, trace.proposal_trace, trace.valid,
        trace.log_weights, trace.log_z_est,
        chosen_idx, output, tokens, logprobs, model_score, score
    )
    # Compute weight update
    up_weight = score - trace.score
    discard = choicemap(:chosen => trace.chosen_idx)
    return new_trace, up_weight, UnknownChange(), discard
end

# Nothing is updated, no arguments changed
update(trace::GPT3ISTrace, ::Tuple, ::NTuple{3, NoChange}, ::EmptyChoiceMap) =
    trace, 0.0, NoChange(), EmptyChoiceMap()

update(trace::GPT3ISTrace, ::Tuple, ::NTuple{3, NoChange}, ::StaticChoiceMap) =
    error("`update`` not implemented for this set of constraints.")

function regenerate(trace::GPT3ISTrace, args::Tuple, argdiffs::Tuple,
                    selection::Selection)
    # Compute argdiffs
    if get_args(trace) == args
        argdiffs = (NoChange(), NoChange(), NoChange())
    end
    # Dispatch to `regenerate` implementations for specific selections
    if isempty(selection)
        return regenerate(trace, args, argdiffs, EmptySelection())
    end
    return regenerate(trace, args, argdiffs, StaticSelection(selection))
end

# Both chosen index and output are selected, no arguments changed
function regenerate(trace::GPT3ISTrace, ::Tuple, ::NTuple{3, NoChange},
                    selection::StaticSelection{(OUTPUT_ADDR, :chosen)})
    # Resample chosen index according to importance weights
    if isnothing(trace.gen_fn.validator)
        chosen_idx = randboltzmann(1:trace.n_samples, trace.log_weights)
    else
        n_trials = length(trace.valid)
        valid_log_weights = resize!(trace.log_weights .* trace.valid, n_trials - 1)
        chosen_idx = randboltzmann(1:(n_trials-1), valid_log_weights)
    end
    # Select output etc. from model trace
    output = trace.model_trace.outputs[chosen_idx]
    tokens = trace.model_trace.tokens[chosen_idx]
    logprobs = trace.model_trace.logprobs[chosen_idx]
    model_score = trace.model_trace.scores[chosen_idx]
    # Compute score and construct trace
    score = model_score - trace.log_z_est
    new_trace = GPT3ISTrace(
        trace.gen_fn, trace.n_samples,
        trace.model_prompt, trace.proposal_prompt,
        trace.model_trace, trace.proposal_trace, trace.valid,
        trace.log_weights, trace.log_z_est,
        chosen_idx, output, tokens, logprobs, model_score, score
    )
    return new_trace, 0.0, UnknownChange()
end

# Everything is selected
regenerate(trace::GPT3ISTrace, args::Tuple, argdiffs::Tuple, ::AllSelection) =
    (simulate(trace.gen_fn, args), 0.0, UnknownChange())

# Nothing is selected, no arguments changed
regenerate(trace::GPT3ISTrace, ::Tuple, ::NTuple{3, NoChange}, ::EmptySelection) =
    trace, 0.0, NoChange()

regenerate(::GPT3ISTrace, ::Tuple, ::Tuple, ::StaticSelection) =
    error("`regenerate` not implemented for this selection.")

regenerate(::GPT3ISTrace, ::Tuple, ::NTuple{3, NoChange}, ::StaticSelection) =
    error("`regenerate` not implemented for this selection.")

"Sample from the standard Gumbel distribution."
function randgumbel()
    return -log(-log(rand()))
end

"Sample from a discrete Boltzmann distribution given unnormalized logprobs."
function randboltzmann(elements, log_weights)
    chosen, chosen_weight = nothing, -Inf
    # Gumbel-max reservoir sampling
    for (elem, weight) in zip(elements, log_weights)
        weight += randgumbel()
        if weight > chosen_weight
            chosen = elem
            chosen_weight = weight
        end
    end
    return chosen
end
