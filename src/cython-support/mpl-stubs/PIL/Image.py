"""PIL.Image stub — see PIL/__init__.py."""

_MSG = ("Image I/O is unavailable in this build: Pillow is not compiled "
        "for wasthon. The Agg render path (canvas) works without it.")


class Image:
    """Placeholder so `isinstance(A, PIL.Image.Image)` is a valid, always-False
    test on array inputs (matplotlib.image.imshow)."""
    pass


def open(*args, **kwargs):
    raise NotImplementedError(_MSG)


def fromarray(*args, **kwargs):
    raise NotImplementedError(_MSG)


LANCZOS = 1
NEAREST = 0
BILINEAR = 2
BICUBIC = 3
