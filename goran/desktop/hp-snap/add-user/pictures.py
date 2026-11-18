#!/usr/bin/env python3
"""Draws HP-OS's own profile pictures. Original artwork, generated here from code, so no outside
image, licence or other system's art is involved. Usage: pictures.py OUTPUT_DIRECTORY"""
import pathlib
import sys

import numpy as np
from PIL import Image

SIZE, SCALE = 512, 2
n = SIZE * SCALE
y, x = np.mgrid[0:n, 0:n] / (n - 1)


def rgb(hex_colour):
    return np.array([int(hex_colour[i:i + 2], 16) for i in (1, 3, 5)], float) / 255


def mix(a, b, t):
    t = np.clip(t, 0, 1)[..., None]
    return a * (1 - t) + b * t


def step(a, b, v):
    t = np.clip((v - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def over(base, colour, alpha):
    return mix(base, colour, alpha)


def daybreak():
    image = mix(rgb("#e4e2f6"), rgb("#f8efe0"), y)
    dx, dy = x - 0.5, y - 0.47
    r = np.hypot(dx, dy)
    light = step(-0.20, 0.26, 0.75 * dx + 0.65 * dy)
    sphere = mix(rgb("#f6f5fb"), rgb("#2a62dc"), light)
    bands = np.hypot(x - 0.02, y - 0.22)
    gold = np.sin(bands * 92) ** 26 * step(0.42, 0.62, bands) * (0.55 + 0.45 * np.sin(bands * 17))
    sphere = over(sphere, rgb("#eaa63e"), gold)
    rim = step(0.25, 0.37, r)
    sphere = over(sphere, rgb("#8fb0f2"), rim * 0.4)
    return over(image, sphere, 1 - step(0.366, 0.372, r))


def tide():
    image = mix(rgb("#fbe8d6"), rgb("#bfe4ff"), step(0, 0.5, y))
    colours = ["#8fd3f7", "#57aeee", "#2f84df", "#1a5ec4", "#0c3a94"]
    for i, colour in enumerate(colours):
        base = 0.40 + i * 0.125
        edge = base + 0.045 * np.sin(x * (7 + i) + i * 1.9) + 0.022 * np.sin(x * (17 - i) + i * 3.1)
        depth = y - edge
        layer = mix(rgb(colour) * 0.55 + 0.45, rgb(colour), step(0, 0.035, depth))
        image = over(image, layer, step(-0.002, 0.002, depth))
    return image


def bloom():
    image = mix(rgb("#fff4ec"), rgb("#ffd8cd"), np.hypot(x - 0.5, y - 0.5) * 1.5)
    dx, dy = x - 0.5, y - 0.5
    for i in range(8):
        angle = i * np.pi / 4 + 0.2
        along = dx * np.cos(angle) + dy * np.sin(angle) - 0.20
        across = -dx * np.sin(angle) + dy * np.cos(angle)
        petal = (along / 0.20) ** 2 + (across / 0.095) ** 2
        colour = mix(rgb("#ffb199"), rgb("#f0386b"), step(-0.18, 0.2, -along))
        image = over(image, colour, (1 - step(0.92, 1.0, petal)) * 0.62)
    centre = np.hypot(dx, dy)
    image = over(image, mix(rgb("#ffe48a"), rgb("#f5a623"), centre / 0.075), 1 - step(0.068, 0.076, centre))
    return image


def dune():
    image = mix(rgb("#ffcf9e"), rgb("#ffe9c8"), step(0, 0.6, y))
    sun = np.hypot(x - 0.68, y - 0.30)
    image = over(image, rgb("#fff6dc"), np.exp(-(sun / 0.17) ** 2) * 0.75)
    image = over(image, rgb("#fffaf0"), 1 - step(0.098, 0.104, sun))
    colours = [("#efa76c", "#d98650"), ("#de8450", "#b9623c"), ("#bb5f3c", "#8f432f"), ("#8a3f2e", "#5a2722")]
    for i, (lit, shade) in enumerate(colours):
        crest = 0.5 + i * 0.13 + 0.07 * np.sin(x * (4.2 + i * 1.3) + i * 2.3) + 0.02 * np.sin(x * 13 + i)
        slope = np.cos(x * (4.2 + i * 1.3) + i * 2.3)
        layer = mix(rgb(lit), rgb(shade), step(-0.6, 0.8, slope) * 0.8 + step(0, 0.3, y - crest) * 0.2)
        image = over(image, layer, step(-0.002, 0.002, y - crest))
    return image


def aurora():
    image = mix(rgb("#060c2c"), rgb("#10285c"), step(0, 0.85, y))
    generator = np.random.default_rng(7)
    for sx, sy, size in zip(generator.random(70), generator.random(70) * 0.62, generator.random(70)):
        star = np.hypot(x - sx, y - sy)
        image = over(image, rgb("#ffffff"), np.exp(-(star / (0.0015 + 0.002 * size)) ** 2) * 0.85)
    for colour, base, wave, phase, reach in [("#6a5cff", 0.34, 0.07, 0.6, 0.26), ("#2ee6c4", 0.46, 0.09, 2.4, 0.30), ("#8dff9c", 0.55, 0.06, 4.1, 0.22)]:
        foot = base + wave * np.sin(x * 5.2 + phase) + 0.025 * np.sin(x * 14 + phase * 2)
        rise = np.where(y < foot, np.exp(-((foot - y) / reach) ** 1.4), np.exp(-((y - foot) / 0.018) ** 2))
        curtain = 0.72 + 0.28 * np.sin(x * 74 + 3 * np.sin(x * 9 + phase))
        image = np.clip(image + rgb(colour) * (rise * curtain * 0.8)[..., None], 0, 1)
    ridge = 0.84 + 0.05 * np.sin(x * 6 + 0.8) + 0.025 * np.sin(x * 19 + 2)
    return over(image, rgb("#040818"), step(-0.002, 0.002, y - ridge))


output = pathlib.Path(sys.argv[1])
output.mkdir(parents=True, exist_ok=True)
for draw in (daybreak, tide, bloom, dune, aurora):
    pixels = (np.clip(draw(), 0, 1) * 255 + 0.5).astype(np.uint8)
    Image.fromarray(pixels).resize((SIZE, SIZE), Image.LANCZOS).save(output / f"{draw.__name__}.jpg", quality=93, subsampling=0)
