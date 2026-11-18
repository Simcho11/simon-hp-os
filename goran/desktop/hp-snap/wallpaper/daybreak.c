/* HP-OS daytime wallpaper: a light twin of the dark planet wallpaper.
 * Original procedural artwork, rendered at any size:
 *   gcc -O2 -fopenmp -o daybreak daybreak.c -lm && ./daybreak 5760 3600 > daybreak.ppm
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct { double r, g, b; } rgb;

static double clamp01(double v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
static double mixd(double a, double b, double t) { return a + (b - a) * t; }
static rgb mix(rgb a, rgb b, double t) { return (rgb){ mixd(a.r, b.r, t), mixd(a.g, b.g, t), mixd(a.b, b.b, t) }; }
static rgb hex(uint32_t c) { return (rgb){ ((c >> 16) & 255) / 255.0, ((c >> 8) & 255) / 255.0, (c & 255) / 255.0 }; }
static double smooth(double a, double b, double x) { double t = clamp01((x - a) / (b - a)); return t * t * (3 - 2 * t); }

static double hash2(int x, int y) {
    uint32_t h = (uint32_t)x * 374761393u + (uint32_t)y * 668265263u;
    h = (h ^ (h >> 13)) * 1274126177u;
    return ((h ^ (h >> 16)) & 0xffffff) / 16777215.0;
}
static double noise(double x, double y) {
    double fx = floor(x), fy = floor(y);
    int ix = (int)fx, iy = (int)fy;
    double tx = x - fx, ty = y - fy;
    tx = tx * tx * tx * (tx * (tx * 6 - 15) + 10);
    ty = ty * ty * ty * (ty * (ty * 6 - 15) + 10);
    return mixd(mixd(hash2(ix, iy), hash2(ix + 1, iy), tx), mixd(hash2(ix, iy + 1), hash2(ix + 1, iy + 1), tx), ty);
}
static double fbm(double x, double y, int octaves) {
    double sum = 0, amp = 0.5, norm = 0;
    for (int i = 0; i < octaves; i++) {
        sum += amp * noise(x, y); norm += amp;
        x = x * 2.03 + 17.1; y = y * 2.03 + 9.7; amp *= 0.5;
    }
    return sum / norm;
}

/* Fine streaks that follow a flow coordinate: bright threads on a calm ground. */
static double threads(double along, double across, double density, double cover) {
    double fine = fbm(along * 0.45, across * density, 5);
    double broad = fbm(along * 0.30 + 5.0, across * density * 0.10 + 3.0, 4);
    double lines = 0.5 + 0.5 * sin((fine * 1.6 + across * density * 0.55) * 6.2831853);
    double mask = smooth(cover - 0.14, cover + 0.14, broad);
    /* Threads of uneven weight over a soft wash of the same colour. */
    return clamp01(pow(lines, 2.2) * mask * (0.55 + 0.9 * fbm(along * 2.0, across * density * 0.5 + 9.0, 3)) + 0.22 * mask * mask);
}

static rgb shade(double x, double y, double px) {
    /* Paper: a soft sky, a little warmer low on the left. */
    rgb col = mix(hex(0xe9f0fb), hex(0xf8f9fc), smooth(0.0, 1.0, y));
    double warm = exp(-((x + 0.75) * (x + 0.75) + (y - 0.62) * (y - 0.62)) / 0.20);
    col = mix(col, hex(0xfff0dd), 0.55 * warm);
    double cool = exp(-((x - 0.62) * (x - 0.62) + (y - 0.18) * (y - 0.18)) / 0.30);
    col = mix(col, hex(0xdde9ff), 0.50 * cool);

    /* The planet. */
    const double cx = 0.02, cy = 0.305, R = 0.335;
    double dx = (x - cx) / R, dy = (y - cy) / R, r = sqrt(dx * dx + dy * dy);
    double dist = (r - 1.0) * R;
    col = mix(col, hex(0xc9dcff), 0.55 * exp(-fmax(dist, 0) / 0.035));   /* atmosphere */
    col = mix(col, hex(0xbfd0ee), 0.10 * exp(-fmax(dist, 0) / 0.16));
    if (r < 1.0 + px / R) {
        double rr = fmin(r, 1.0), z = sqrt(1.0 - rr * rr);
        double nx = dx, ny = dy, nz = z;
        /* Bands wrap an axis leaning toward the viewer, so they read as arcs. */
        const double ax = 0.80, ay = 0.28, az = 0.53;
        double lat = asin(clamp01((nx * ax + ny * ay + nz * az) * 0.5 + 0.5) * 2 - 1);
        double bx = -0.33 * nx + 0.94 * ny + 0.0 * nz, bz = -0.50 * nx - 0.18 * ny + 0.85 * nz;
        double lon = atan2(bx, bz);
        double light = clamp01(nx * -0.52 + ny * -0.55 + nz * 0.65);
        rgb body = mix(hex(0x5f86e2), hex(0xf7faff), smooth(0.0, 0.92, light));
        body = mix(body, hex(0xa9c4f6), 0.35 * smooth(0.3, 0.9, fbm(lat * 3.0 + 2.0, lon * 0.6, 4)));
        double gold = threads(lon * 1.1, lat + 0.04 * fbm(lon * 1.5, lat * 3.0, 3), 26.0, 0.48);
        double where = smooth(-0.95, -0.25, lat) * (1.0 - smooth(0.70, 1.15, lat));
        body = mix(body, mix(hex(0xe39a3a), hex(0xffd994), light), 0.88 * gold * where);
        double rim = pow(1.0 - z, 3.0);
        body = mix(body, hex(0x8fb6ff), 0.55 * rim * (1.0 - light * 0.6));
        body = mix(body, hex(0xffffff), 0.35 * pow(light, 6.0));
        col = mix(col, body, clamp01(0.5 - dist / px));
    }

    /* The horizon: a second world close by, its surface combed into flowing gold threads. */
    const double hx = 0.05, hy = 2.58, HR = 1.86;
    double hd = sqrt((x - hx) * (x - hx) + (y - hy) * (y - hy)) - HR;
    col = mix(col, hex(0xcfe0ff), 0.60 * exp(-fmax(hd, 0) / 0.030));
    if (hd < px) {
        double depth = -hd;
        /* Threads run with the limb and wander: combed, never knotted. */
        double along = atan2(x - hx, hy - y) * HR;
        double wander = 0.22 * (fbm(along * 1.1 + 11.0, depth * 2.2, 4) - 0.5) + 0.10 * (fbm(along * 3.3 + 37.0, depth * 6.0 + 5.0, 3) - 0.5);
        double across = depth + wander;
        double qx = along, qy = across;
        rgb ground = mix(hex(0xdce7fb), hex(0x9fbcf3), smooth(0.25, 0.75, fbm(along * 0.8 + 4.0, across * 7.0, 4)));
        double gold = threads(along * 1.3 + 8.0, across + 1.7, 78.0, 0.45);
        ground = mix(ground, mix(hex(0xe7a040), hex(0xffdfa6), fbm(qx * 3.0, qy * 9.0, 3)), 0.85 * gold);
        ground = mix(ground, hex(0x9dbcf7), 0.50 * exp(-depth / 0.012));       /* lit limb */
        ground = mix(ground, hex(0xffffff), 0.55 * exp(-depth / 0.004));
        ground = mix(ground, hex(0xf2f5fb), 0.62 * smooth(0.84, 1.0, y));      /* calm under the Dock and status bar */
        col = mix(col, ground, clamp01(0.5 - hd / px));
    }
    return col;
}

int main(int argc, char **argv) {
    int W = argc > 1 ? atoi(argv[1]) : 2880, H = argc > 2 ? atoi(argv[2]) : 1800;
    uint8_t *out = malloc((size_t)W * H * 3);
    double px = 1.0 / H;
    #pragma omp parallel for schedule(dynamic, 16)
    for (int j = 0; j < H; j++) {
        for (int i = 0; i < W; i++) {
            rgb sum = { 0, 0, 0 };
            for (int s = 0; s < 4; s++) {   /* 2x2 samples keep the threads clean */
                double x = (i + 0.25 + 0.5 * (s & 1) - W / 2.0) / H, y = (j + 0.25 + 0.5 * (s >> 1)) / (double)H;
                rgb c = shade(x, y, px);
                sum.r += c.r; sum.g += c.g; sum.b += c.b;
            }
            double dither = (hash2(i * 3 + 1, j * 7 + 5) - 0.5) / 255.0;
            uint8_t *p = out + ((size_t)j * W + i) * 3;
            p[0] = (uint8_t)(clamp01(sum.r / 4 + dither) * 255.0 + 0.5);
            p[1] = (uint8_t)(clamp01(sum.g / 4 + dither) * 255.0 + 0.5);
            p[2] = (uint8_t)(clamp01(sum.b / 4 + dither) * 255.0 + 0.5);
        }
    }
    printf("P6\n%d %d\n255\n", W, H);
    fwrite(out, 3, (size_t)W * H, stdout);
    return 0;
}
