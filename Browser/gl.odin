package main

// Minimal GL bindings for texture creation (testing only)

import "core:c"

foreign import gl "system:GL"

GL_TEXTURE_2D         : c.uint : 0x0DE1
GL_RGBA               : c.uint : 0x1908
GL_UNSIGNED_BYTE      : c.uint : 0x1401
GL_TEXTURE_MIN_FILTER : c.uint : 0x2801
GL_TEXTURE_MAG_FILTER : c.uint : 0x2800
GL_LINEAR             : c.int  : 0x2601

@(default_calling_convention = "c")
foreign gl {
    @(link_name = "glGenTextures")
    gl_gen_textures :: proc(n: c.int, textures: ^c.uint) ---

    @(link_name = "glBindTexture")
    gl_bind_texture :: proc(target: c.uint, texture: c.uint) ---

    @(link_name = "glTexImage2D")
    gl_tex_image_2d :: proc(target: c.uint, level: c.int, internalformat: c.int,
                            width, height: c.int, border: c.int,
                            format: c.uint, type: c.uint, pixels: rawptr) ---

    @(link_name = "glTexParameteri")
    gl_tex_parameteri :: proc(target: c.uint, pname: c.uint, param: c.int) ---

    @(link_name = "glDeleteTextures")
    gl_delete_textures :: proc(n: c.int, textures: ^c.uint) ---
}
