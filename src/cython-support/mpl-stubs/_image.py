# matplotlib._image stub: the C module's PyInit aborts under the bridge;
# only the interpolation constants are needed at import (Agg draws paths
# and text without resampling).
def resample(*args, **kwargs):
    raise NotImplementedError("matplotlib._image C module not available")

NEAREST, BILINEAR, BICUBIC, SPLINE16, SPLINE36, HANNING, HAMMING, HERMITE, \
    KAISER, QUADRIC, CATROM, GAUSSIAN, BESSEL, MITCHELL, SINC, LANCZOS, \
    BLACKMAN = range(17)
