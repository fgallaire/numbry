"""Minimal PIL/Pillow stub for the wasthon matplotlib build.

matplotlib imports PIL.Image and PIL.PngImagePlugin at module import time
(colors.py, image.py) but only *uses* them at the I/O frontier
(imread/imsave/savefig-png, colormap _repr_png_). The Agg render path
(buffer_rgba -> canvas) never touches PIL. This stub lets `import
matplotlib` succeed and raises a clear error only if image I/O is actually
attempted. Swap for a real Pillow port to enable imread/imsave.
"""
__version__ = "0.0.0-wasthon-stub"
