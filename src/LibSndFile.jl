# precompile is now the default
VERSION < v"0.7.0-rc2" && __precompile__()

module LibSndFile

using SampledSignals
import SampledSignals: nchannels, nframes, samplerate, unsafe_read!, unsafe_write
using FileIO
if VERSION >= v"0.7-"
    using Printf: @printf
    using LinearAlgebra: transpose!
else
    using Compat: Cvoid
end

function __init__()
    # this needs to be run when the module is loaded at run-time, even if
    # the module is precompiled.
    del_format(format"WAV")
    add_format(format"WAV", detectwav, ".wav", [:LibSndFile])
    del_format(format"FLAC")
    add_format(format"FLAC", "fLaC", ".flac", [:LibSndFile])
    add_format(format"OGG", "OggS", [".ogg", ".oga"], [:LibSndFile])
end

include("libsndfile_h.jl")
depsjl = joinpath(@__DIR__, "..", "deps", "deps.jl")
if isfile(depsjl)
    include(depsjl)
else
    error("LibSndFile not properly installed. Please run Pkg.build(\"LibSndFile\")")
end

# WAV is a subtype of RIFF, as is AVI
function detectwav(io)
    seekstart(io)
    magic = String(read!(io, Array{UInt8}(undef, 4)))
    magic == "RIFF" || return false
    seek(io, 8)
    submagic = String(read!(io, Array{UInt8}(undef, 4)))

    submagic == "WAVE"
end

mutable struct SndFileSink{T} <: SampleSink
    path::String
    filePtr::Ptr{Cvoid}
    sfinfo::SF_INFO
    nframes::Int64
    writebuf::Array{T, 2}
end

function SndFileSink(path, filePtr, sfinfo, bufsize=4096)
    T = fmt_to_type(sfinfo.format)
    writebuf = zeros(T, sfinfo.channels, bufsize)
    SndFileSink(path, filePtr, sfinfo, 0, writebuf)
end

nchannels(sink::SndFileSink) = Int(sink.sfinfo.channels)
samplerate(sink::SndFileSink) = sink.sfinfo.samplerate
nframes(sink::SndFileSink) = sink.nframes
Base.eltype(sink::SndFileSink) = fmt_to_type(sink.sfinfo.format)

mutable struct SndFileSource{T} <: SampleSource
    path::String
    filePtr::Ptr{Cvoid}
    sfinfo::SF_INFO
    pos::Int64
    readbuf::Array{T, 2}
end

function SndFileSource(path, filePtr, sfinfo, bufsize=4096)
    T = fmt_to_type(sfinfo.format)
    readbuf = zeros(T, sfinfo.channels, bufsize)

    SndFileSource(path, filePtr, sfinfo, 1, readbuf)
end

nchannels(source::SndFileSource) = Int(source.sfinfo.channels)
samplerate(source::SndFileSource) = source.sfinfo.samplerate
nframes(source::SndFileSource) = source.sfinfo.frames
Base.eltype(source::SndFileSource{T}) where T = T

function Base.show(io::IO, s::Union{SndFileSource, SndFileSink})
    println(io, typeof(s))
    println(io, "  path: \"$(s.path)\"")
    println(io, "  channels: ", nchannels(s))
    println(io, "  samplerate: ", samplerate(s), "Hz")
    # SndFileSinks don't have a position and we're always at the end
    pos = isa(s, SndFileSource) ? s.pos-1 : nframes(s)
    postime = float((pos)/samplerate(s))
    endtime = float((nframes(s))/samplerate(s))
    println(io, "  position: $(pos) of $(nframes(s)) frames")
    @printf(io, "            %0.2f of %0.2f seconds", postime, endtime)
end

loadstreaming(path::AbstractString, args...; kwargs...) =
    loadstreaming(query(path), args...; kwargs...)

function loadstreaming(f::Function, args...)
    str = loadstreaming(args...)
    try
        f(str)
    finally
        close(str)
    end
end

function loadstreaming(path::File)
    sfinfo = SF_INFO(0, 0, 0, 0, 0, 0)
    fname = filename(path)
    # sf_open fills in sfinfo
    filePtr = sf_open(fname, SFM_READ, sfinfo)

    SndFileSource(fname, filePtr, sfinfo)
end

function Base.close(s::SndFileSource)
    sf_close(s.filePtr)
end

function unsafe_read!(source::SndFileSource, buf::Array, frameoffset, framecount)
    total = min(framecount, nframes(source) - source.pos + 1)
    nread = 0
    readbuf = source.readbuf
    while nread < total
        n = min(size(readbuf, 2), total - nread)
        nr = sf_readf(source.filePtr, readbuf, n)
        # the data comes in interleaved, so we need to transpose
        transpose!(view(buf, (1:nr) .+ frameoffset .+ nread, :),
                   view(readbuf, :, 1:nr))
        source.pos += nr
        nread += nr
        nr == n || break
    end

    nread
end

load(path::File{format"WAV"}) = load_helper(path)
load(path::File{format"FLAC"}) = load_helper(path)
load(path::File{format"OGG"}) = load_helper(path)
function load_helper(path::File)
    str = loadstreaming(path)
    buf = try
        read(str)
    finally
        close(str)
    end

    buf
end

savestreaming(path::AbstractString, args...; kwargs...) =
    savestreaming(query(path), args...; kwargs...)

function savestreaming(f::Function, args...)
    stream = savestreaming(args...)
    try
        f(stream)
    finally
        close(stream)
    end
end

function savestreaming(path::File{T}, nchannels, samplerate, elemtype) where T
    sfinfo = SF_INFO(0, 0, 0, 0, 0, 0)

    sfinfo.samplerate = samplerate
    sfinfo.channels = nchannels
    sfinfo.format = formatcode(T)
    # TODO: should we auto-convert 32-bit integer samples to 24-bit?
    if T == format"FLAC" && elemtype != PCM16Sample
        error("LibSndFile.jl: FLAC only supports 16-bit integer samples")
    end
    if T == format"OGG"
        sfinfo.format |= SF_FORMAT_VORBIS
    else
        sfinfo.format |= subformatcode(elemtype)
    end

    filePtr = ccall((:sf_open, libsndfile), Ptr{Cvoid},
                    (Ptr{UInt8}, Int32, Ref{SF_INFO}),
                    filename(path), SFM_WRITE, sfinfo)

    if filePtr == C_NULL
        errmsg = ccall((:sf_strerror, libsndfile), Ptr{UInt8}, (Ptr{Cvoid},), filePtr)
        error("LibSndFile.jl error while saving $path: ", unsafe_string(errmsg))
    end

    SndFileSink(filename(path), filePtr, sfinfo)
end

# returns the number of samples written
function unsafe_write(sink::SndFileSink, buf::Array, frameoffset, framecount)
    nwritten = 0
    writebuf = sink.writebuf
    while nwritten < framecount
        n = min(size(writebuf, 2), framecount - nwritten)
        # the data needs to be interleaved, so we need to transpose
        transpose!(view(writebuf, :, 1:n),
                   view(buf, (1:n) .+ frameoffset .+ nwritten, :))
        nw = sf_writef(sink.filePtr, writebuf, n)
        sink.nframes += nw
        nwritten += nw
        nw == n || break
    end

    nwritten
end

function Base.close(str::SndFileSink)
    err = ccall((:sf_close, libsndfile), Int32, (Ptr{Cvoid},), str.filePtr)
    if err != 0
        error("LibSndFile.jl error while saving $path: Failed to close file")
    end
end

save(path::File{format"WAV"},buf::SampleBuf) = save_helper(path,buf)
save(path::File{format"FLAC"},buf::SampleBuf) = save_helper(path,buf)
save(path::File{format"OGG"},buf::SampleBuf) = save_helper(path,buf)
function save_helper(path::File, buf::SampleBuf)
    sfinfo = SF_INFO(0, 0, 0, 0, 0, 0)
    stream = savestreaming(path, nchannels(buf), samplerate(buf), eltype(buf))

    try
        frameswritten = write(stream, buf)
        if frameswritten != nframes(buf)
            error("Only wrote $frameswritten frames, expected $(nframes(buf))")
        end
    finally
        # make sure we close the file even if something goes wrong
        close(stream)
    end

    nothing
end

"""
Wrappers for the family of sf_readf_* functions, which read the given number
of frames into the given array. Returns the number of frames read.
"""
function sf_readf end

sf_readf(filePtr, dest::Array{T}, nframes) where T <: Union{Int16, PCM16Sample} =
    ccall((:sf_readf_short, libsndfile), Int64,
        (Ptr{Cvoid}, Ptr{T}, Int64),
        filePtr, dest, nframes)

sf_readf(filePtr, dest::Array{T}, nframes) where T <: Union{Int32, PCM32Sample} =
    ccall((:sf_readf_int, libsndfile), Int64,
        (Ptr{Cvoid}, Ptr{T}, Int64),
        filePtr, dest, nframes)

sf_readf(filePtr, dest::Array{Float32}, nframes) =
    ccall((:sf_readf_float, libsndfile), Int64,
        (Ptr{Cvoid}, Ptr{Float32}, Int64),
        filePtr, dest, nframes)

sf_readf(filePtr, dest::Array{Float64}, nframes) =
    ccall((:sf_readf_double, libsndfile), Int64,
        (Ptr{Cvoid}, Ptr{Float64}, Int64),
        filePtr, dest, nframes)

"""
Wrappers for the family of sf_writef_* functions, which write the given number
of frames into the given array. Returns the number of frames written.
"""
function sf_writef end

sf_writef(filePtr, src::Array{T}, nframes) where T <: Union{Int16, PCM16Sample} =
    ccall((:sf_writef_short, libsndfile), Int64,
                (Ptr{Cvoid}, Ptr{T}, Int64),
                filePtr, src, nframes)

sf_writef(filePtr, src::Array{T}, nframes) where T <: Union{Int32, PCM32Sample} =
    ccall((:sf_writef_int, libsndfile), Int64,
                (Ptr{Cvoid}, Ptr{T}, Int64),
                filePtr, src, nframes)

sf_writef(filePtr, src::Array{Float32}, nframes) =
    ccall((:sf_writef_float, libsndfile), Int64,
                (Ptr{Cvoid}, Ptr{Float32}, Int64),
                filePtr, src, nframes)

sf_writef(filePtr, src::Array{Float64}, nframes) =
    ccall((:sf_writef_double, libsndfile), Int64,
                (Ptr{Cvoid}, Ptr{Float64}, Int64),
                filePtr, src, nframes)

#
# function Base.seek(file::AudioFile, offset::Integer, whence::Integer)
#     new_offset = ccall((:sf_seek, libsndfile), Int64,
#         (Ptr{Cvoid}, Int64, Int32), file.filePtr, offset, whence)
#
#     if new_offset < 0
#         error("Could not seek to $(offset) in file")
#     end
#
#     new_offset
# end
#
# # Some convenience methods for easily navigating through a sound file
# Base.seek(file::AudioFile, offset::Integer) = seek(file, offset, SF_SEEK_SET)
# rewind(file::AudioFile) = seek(file, 0, SF_SEEK_SET)

end # module LibSndFile
