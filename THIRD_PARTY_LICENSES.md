# Third-Party Licenses

AstralTV bundles or links the components below. Each keeps its own license. The in-app licenses screen (Settings > About) shows the same information.

The full text of each license is available from the upstream project. Where a component is dual licensed, the table names the branch AstralTV uses.

| Component | License | Notes | Upstream |
| --- | --- | --- | --- |
| MPVKit, mpv & FFmpeg | LGPL-3.0-or-later | Media engine. Built without `--enable-gpl`. Dynamically linked XCFramework. | github.com/mpvkit/MPVKit |
| libass | ISC | Subtitle rendering. | github.com/libass/libass |
| FreeType | FTL (FreeType License) | Font rasterization. FTL branch used. | freetype.org |
| HarfBuzz | MIT | Text shaping. | github.com/harfbuzz/harfbuzz |
| FriBidi | LGPL-2.1-or-later | Bidirectional text. Dynamically linked. | github.com/fribidi/fribidi |
| libunibreak | zlib | Line breaking. | github.com/adah1972/libunibreak |
| OpenSSL 3.3.5 | Apache-2.0 | TLS and cryptography. | github.com/openssl/openssl |
| GnuTLS 3.8.11 | LGPL-2.1-or-later | TLS implementation. Dynamically linked. | gnutls.org |
| GMP | LGPL-3.0-or-later | Arbitrary-precision arithmetic. LGPL-3.0 branch used. | gmplib.org |
| Nettle | LGPL-3.0-or-later | Cryptography. LGPL-3.0 branch used. | lysator.liu.se/~nisse/nettle |
| Hogweed | LGPL-3.0-or-later | Public-key half of Nettle. LGPL-3.0 branch used. | lysator.liu.se/~nisse/nettle |
| libplacebo | LGPL-2.1-or-later | GPU rendering and color management. Dynamically linked. | code.videolan.org/videolan/libplacebo |
| shaderc | Apache-2.0 | Shader compilation for libplacebo. | github.com/google/shaderc |
| MoltenVK 1.4.2 | Apache-2.0 | Vulkan on Metal. | github.com/KhronosGroup/MoltenVK |
| Little CMS (lcms2) | MIT | Color management. | littlecms.com |
| libdovi | MIT | HDR RPU metadata parsing. | github.com/quietvoid/dovi_tool |
| dav1d | BSD-2-Clause | AV1 decoder. | code.videolan.org/videolan/dav1d |
| libuavs3d | BSD-3-Clause | AVS3 decoder. | github.com/uavs3/uavs3d |
| libbluray | LGPL-2.1-or-later | Bundled by MPVKit. Not used by any AstralTV feature. | code.videolan.org/videolan/libbluray |
| libuchardet | MPL-1.1 | Character set detection. MPL-1.1 branch used. | freedesktop.org/wiki/Software/uchardet |
| SwiftDraw | zlib | SVG rendering for channel logos. | github.com/swhitty/SwiftDraw |
| Protocol Buffers (Objective-C runtime) | BSD-3-Clause | Pulled in by the Google Cast SDK. | github.com/protocolbuffers/protobuf |
| GTMSessionFetcher | Apache-2.0 | Pulled in by the Google Cast SDK. | github.com/google/gtm-session-fetcher |
| Google Cast SDK | Proprietary | Subject to Google's terms. A GPL section 7 linking exception applies. See [LICENSE-EXCEPTIONS.md](LICENSE-EXCEPTIONS.md). | developers.google.com/cast |

## Requests for source

For LGPL, MPL, and GPL components, the corresponding source is available from the upstream projects listed above. You can also request it by opening an issue at [github.com/CRZX1337/AstralTV/issues](https://github.com/CRZX1337/AstralTV/issues).

The LGPL components are dynamically linked XCFrameworks. You can replace them with a modified build by changing the MPVKit Swift Package dependency and rebuilding the app.
