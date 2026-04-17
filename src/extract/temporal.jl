"""Parse natural-language or ISO temporal expressions relative to a reference time."""

parse_temporal(::Nothing, ::DateTime) = nothing

function parse_temporal(text, reference_time::DateTime)::Union{Nothing, DateTime}
    text === nothing && return nothing
    s = strip(string(text))
    if isempty(s) || lowercase(s) == "null" || lowercase(s) == "nothing"
        return nothing
    end

    for fmt in (
        dateformat"yyyy-mm-ddTHH:MM:SS.sssZ",
        dateformat"yyyy-mm-ddTHH:MM:SSZ",
        dateformat"yyyy-mm-ddTHH:MM:SS",
        dateformat"yyyy-mm-dd",
    )
        try
            return DateTime(s, fmt)
        catch
        end
    end

    lower = lowercase(s)
    if occursin("yesterday", lower)
        return reference_time - Day(1)
    elseif occursin("last week", lower)
        return reference_time - Week(1)
    elseif occursin("last month", lower)
        return reference_time - Month(1)
    elseif occursin("last year", lower)
        return reference_time - Year(1)
    elseif occursin("now", lower) || occursin("today", lower)
        return reference_time
    end
    return nothing
end
