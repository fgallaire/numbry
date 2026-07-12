"""PIL.PngImagePlugin stub — see PIL/__init__.py."""


class PngInfo:
    def __init__(self):
        self.chunks = []

    def add_text(self, key, value, zip=False):
        self.chunks.append((key, value))


class PngImageFile:
    pass
