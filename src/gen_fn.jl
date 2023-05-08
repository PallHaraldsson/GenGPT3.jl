## GPT3ChoiceMap ##

const OUTPUT_ADDR = :output

"""
    GPT3ChoiceMap

An alias for the static choicemap associated with [`GPT3Trace`](@ref). 

    choices = GPT3ChoiceMap(output::String)

Constructs a static choicemap for the trace of a [`GPT3GenerativeFunction`](@ref).
"""
const GPT3ChoiceMap =
    Gen.StaticChoiceMap{(OUTPUT_ADDR,), Tuple{String}, (), Tuple{}}

GPT3ChoiceMap(output::String) =
    Gen.StaticChoiceMap(NamedTuple{(OUTPUT_ADDR,)}((output,)), NamedTuple(), false)

## GPT3Trace ##

"""
    GPT3Trace

A trace generated by a [`GPT3GenerativeFunction`](@ref). This trace has 
exactly one choice address, `$OUTPUT_ADDR`, denoting the completion output
generated by GPT-3. The return value is also the completion output.

# Fields
- `gen_fn`:
    The [`GPT3GenerativeFunction`](@ref) that is the source of the trace.
- `prompt::String`:
    The prompt provided as an argument to GPT-3.
- `output::String`:
    The output completion generated by GPT-3.
- `tokens::Vector{String}`:
    List of output tokens, including the stop sequence.
- `logprobs::Vector{Float64}`:
    The log probability of each token. Unnormalized when temperature is not 1.0.
- `score::Float64`:
    The total log probability of generating the output.
"""
struct GPT3Trace{T <: GenerativeFunction} <: Trace
    gen_fn::T
    prompt::String
    output::String
    tokens::Vector{String}
    logprobs::Vector{Float64}
    score::Float64
end

get_choices(trace::GPT3Trace) = GPT3ChoiceMap(trace.output)
get_args(trace::GPT3Trace) = (trace.prompt,)
get_retval(trace::GPT3Trace) = trace.output
get_score(trace::GPT3Trace) = trace.score
get_gen_fn(trace::GPT3Trace) = trace.gen_fn

function Base.:(==)(trace1::GPT3Trace, trace2::GPT3Trace)
    return (trace1.gen_fn == trace2.gen_fn &&
            trace1.prompt == trace2.prompt &&
            trace1.output == trace2.output &&
            trace1.tokens == trace2.tokens &&
            trace1.logprobs == trace2.logprobs &&
            trace1.score == trace2.score)
end

## GPT3GenerativeFunction ##

"""
    GPT3GenerativeFunction(;
        model = "text-davinci-002",
        temperature = 1.0,
        max_tokens = 1024,
        stop = nothing,
        api_key_lookup = () -> ENV["OPENAI_API_KEY"],
        organization_lookup = () -> ENV["OPENAI_ORGANIZATION"]
    )

Constructs GPT-3 as a generative function, where sampling and scoring of
completions are performed via calls to the OpenAI API.

The generative function takes in a prompt as an (optional) argument, then
samples and returns a completion. This represents a distribution over strings
(up to `max_tokens` long) which end in a `stop` sequence. The completion is
stored in the `$OUTPUT_ADDR` address of the resulting trace.

# Arguments
- `model::String`:
    The pretrained model to query. Defaults to `"text-davinci-002"`.
- `temperature::Float64 = 1.0`:
    The softmax temperature. Values between `0.0`` and `2.0` are allowed.
    Higher temperatures increase randomness. Note that if this is not set
    to `1.0`, then the resulting log probabilities will no longer be normalized.
- `max_tokens::Int = 1024`:
    The maximum number of output tokens generated (including the stop sequence).
- `stop::Union{String,Nothing} = nothing`:
    The stop sequence as a string. Defaults to the `<|endoftext|>` token if not
    specified. If specified, then the model will be prevented from generating
    any `<|endoftext|>` tokens (to avoid multiple termination possibilities).
- `api_key_lookup::Function`:
    A zero-argument function that returns the OpenAI API key to use. Defaults to
    looking up the `"OPENAI_API_KEY"` environment variable.
- `organization_lookup::Function`:
    A zero-argument function that returns the OpenAI organization ID to use.
    Defaults to the `"OPENAI_ORGANIZATION"` environment variable, if specified.
"""
@kwdef struct GPT3GenerativeFunction <: GenerativeFunction{String,GPT3Trace}
    model::String = "text-davinci-002"
    temperature::Float64 = 1.0
    max_tokens::Int = 1024
    stop::Union{String,Nothing} = nothing
    n_stop::Int = isnothing(stop) ? 1 : length(tokenize(stop))
    api_key_lookup::Function = lookup_openai_api_key
    organization_lookup::Function = lookup_openai_organization
end

"""
    GPT3GF

An alias for [`GPT3GenerativeFunction`](@ref).
"""
const GPT3GF = GPT3GenerativeFunction

"""
    (gpt3::GPT3GenerativeFunction)(prompt::String="")

Untraced execution of a [`GPT3GenerativeFunction`]. Calls GPT-3 with an optional
`prompt` via the OpenAI API, and returns the resulting completion.
"""
(gen_fn::GPT3GenerativeFunction)(prompt::String="") =
    get_retval(simulate(gen_fn, (prompt,)))

function simulate(gen_fn::GPT3GF, args::Tuple)
    # Extract prompt
    prompt = args[1]

    # Call GPT3 API 
    response = gpt3_api_call(
        prompt;
        model=gen_fn.model,
        temperature=gen_fn.temperature,
        max_tokens=gen_fn.max_tokens,
        stop=gen_fn.stop,
        logit_bias=standardize_logit_bias(nothing, gen_fn.stop),
        api_key=gen_fn.api_key_lookup(),
        organization=gen_fn.organization_lookup()
    )
    completion = response.choices[1]

    # Evaluate probability of completion by calling `generate`
    trace, _ = generate(gen_fn, args, GPT3ChoiceMap(completion.text))

    return trace
end

simulate(gen_fn::GPT3GF, args::Tuple{}) =
    simulate(gen_fn, ("",))

function generate(gen_fn::GPT3GF, args::Tuple, constraints::ChoiceMap)
    # Check whether output is constrained
    if !has_value(constraints, OUTPUT_ADDR)
        return generate(gen_fn, args, EmptyChoiceMap())
    end

    # Extract prompt and constrained output
    prompt = args[1]
    output = get_value(constraints, OUTPUT_ADDR)

    # Construct full text from prompt and output
    full_text = construct_full_text(gen_fn.max_tokens, prompt, output,
                                    gen_fn.stop, gen_fn.n_stop)

    # If nothing is returned, then the constrained output is too long
    if isnothing(full_text)
        score = -Inf
        trace = GPT3Trace(gen_fn, prompt, output, [], [], score)
        return trace, score
    end

    # Call GPT3 API to evaluate log probabilities
    response = gpt3_api_call(
        full_text::Union{String, Vector{Int}},
        logprobs=0,
        model=gen_fn.model,
        temperature=gen_fn.temperature,
        max_tokens=0,
        echo=true,
        stop=gen_fn.stop,
        logit_bias=standardize_logit_bias(nothing, gen_fn.stop),
        api_key=gen_fn.api_key_lookup(),
        organization=gen_fn.organization_lookup()
    )
    completion = response.choices[1]

    # Construct trace from completion
    tokens, logprobs = extract_tokens_after_prompt(completion, prompt)
    logprobs = gen_fn.temperature == 0.0 ?
        zeros(Float64, length(tokens)) : logprobs ./ gen_fn.temperature
    score = isempty(logprobs) ? 0.0 : sum(logprobs)
    trace = GPT3Trace(gen_fn, prompt, output, tokens, logprobs, score) 

    return trace, score    
end

generate(gen_fn::GPT3GF, args::Tuple{}, constraints::ChoiceMap) =
    generate(gen_fn, ("",), constraints)

generate(gen_fn::GPT3GF, args::Tuple, ::EmptyChoiceMap) =
    simulate(gen_fn, args), 0.0

generate(gen_fn::GPT3GF, args::Tuple{}, ::EmptyChoiceMap) =
    simulate(gen_fn, args), 0.0

project(trace::GPT3Trace, selection::Selection) =
    OUTPUT_ADDR in selection ? trace.score : 0.0   

project(trace::GPT3Trace, ::EmptySelection) =
    0.0

function update(trace::GPT3Trace, args::Tuple, argdiffs::Tuple, constraints::ChoiceMap)
    # Check whether output is constrained
    if isempty(constraints)
        return update(trace, args, argdiffs, EmptyChoiceMap())
    elseif !has_value(constraints, OUTPUT_ADDR)
        error("Did not visit all constraints")
    end

    # Return same trace if both prompt and output do not change
    prompt, diff = args[1], argdiffs[1]
    output = get_value(constraints, OUTPUT_ADDR)
    if (diff isa NoChange || prompt == trace.prompt) && output == trace.output
        return trace, 0.0, NoChange(), EmptyChoiceMap()
    end

    # Generate new trace otherwise, and return change in score
    new_trace, _ = generate(trace.gen_fn, args, constraints)
    weight = new_trace.score - trace.score
    discard = get_choices(trace)
    return new_trace, weight, UnknownChange(), discard
end

function update(trace::GPT3Trace, args::Tuple, argdiffs::Tuple, ::EmptyChoiceMap)
    # Return same trace if prompt does not change
    prompt, diff = args[1], argdiffs[1]
    if diff isa NoChange || prompt == trace.prompt
        return trace, 0.0, NoChange(), EmptyChoiceMap()
    end

    # Generate new trace with old choices otherwise, and return change in score
    choices = get_choices(trace)
    new_trace, _ = generate(trace.gen_fn, args, choices)
    weight = new_trace.score - trace.score
    return new_trace, weight, NoChange(), EmptyChoiceMap()
end

update(trace::GPT3Trace, ::Tuple{}, ::Tuple{}, constraints::ChoiceMap) =
    update(trace, ("",), (UnknownChange()), constraints)

function regenerate(trace::GPT3Trace, args::Tuple, argdiffs::Tuple, selection::Selection)
    # Check whether output is selected
    if isempty(selection)
        return regenerate(trace, args, argdiffs, EmptySelection())
    end

    # Simulate new trace and return no change in score
    new_trace = simulate(trace.gen_fn, args)
    return new_trace, 0.0, UnknownChange()
end

function regenerate(trace::GPT3Trace, args::Tuple, argdiffs::Tuple, ::EmptySelection)
    # Return same trace if prompt does not change
    prompt, diff = args[1], argdiffs[1]
    if diff isa NoChange || prompt == trace.prompt
        return trace, 0.0, NoChange()
    end

    # Generate new trace with old choices otherwise, and return change in score
    choices = get_choices(trace)
    new_trace, _ = generate(trace.gen_fn, args, choices)
    weight = new_trace.score - trace.score
    return new_trace, weight, NoChange()
end

regenerate(trace::GPT3Trace, ::Tuple{}, ::Tuple{}, selection::Selection) =
    regenerate(trace, ("",), (UnknownChange()), selection)
