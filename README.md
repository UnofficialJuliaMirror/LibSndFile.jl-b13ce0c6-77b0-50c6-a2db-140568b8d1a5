LibSndFile.jl
=============

[![Build Status](https://travis-ci.org/JuliaAudio/LibSndFile.jl.svg?branch=master)] (https://travis-ci.org/JuliaAudio/LibSndFile.jl)
[![codecov.io](https://codecov.io/github/JuliaAudio/LibSndFile.jl/coverage.svg?branch=master)](https://codecov.io/github/JuliaAudio/LibSndFile.jl?branch=master)

LibSndFile.jl is a wrapper for [libsndfile](http://www.mega-nerd.com/libsndfile/), and supports a wide variety of file and sample formats. The package uses the [FileIO](https://github.com/JuliaIO/FileIO.jl) `load` and `save` interface to automatically figure out the file type of the file to be opened, and the file contents are represented as a `SampleBuf`. For streaming I/O the LibSndFile.jl library also has an `open` method accessible with `LibSndFile.open`, which has a similar interface to `Base.open`. The results are represented as a `SampleSource` (for reading), or a `SampleSink` (for writing). These buffer and stream types are defined in the [SampledSignals](https://github.com/JuliaAudio/SampledSignals.jl) package.

## Examples

**Read ogg file, write first 1024 samples of the first channel to new wav file**
```julia
x = load("myfile.ogg")
save("myfile_short.wav", x[1:1024])
```

**Read file, write the first second of all channels to a new file**
```julia
x = load("myfile.ogg")
save("myfile_short.wav", x[0s..1s, :])
```

**Read stereo file, write mono mix**
```julia
x = load("myfile.wav")
save("myfile_mono.wav", x[:, 1] + x[:, 2])
```

**Plot the left channel**
```julia
x = load("myfile.wav")
plot(x[:, 1]) # plots with samples on the x axis
plot(domain(x), x[:, 1]) # plots with time on the x axis
```

**Plot the spectrum of the left channel**
```julia
x = load("myfile.wav")
f = fft(x) # returns a FrequencySampleBuf
plot(domain(x), x[:, 1]) # plots with frequency on the x axis
```

**Load a long file as a stream and plot the left channel from 2s to 3s**
```julia
s = loadstream("myfile.ogg")
x = read(s, 4s)[2s..3s, 1]
close(s)
plot(domain(x), x)
```

**To handle closing the file automatically (including in the case of unexpected exceptions), we support the `do` block syntax**

```julia
data = loadstream("data/never_gonna_give_you_up.ogg") do s
    readall(f)
end
```

## A Note on Licensing

libsndfile is [licensed](http://www.mega-nerd.com/libsndfile/#Licensing) under the LGPL, which is very permissive providing that libsndfile is dynamically linked. LibSndFile.jl is licensed under the MIT license, allowing you to statically compile the wrapper into your Julia application. Remember that you must still abide by the terms of the libsndfile license when using this wrapper, in terms of whether libsndfile is statically or dynamically linked.
