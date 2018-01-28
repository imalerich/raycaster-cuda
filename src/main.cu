#define GLEW_STATIC
#include <GL/glew.h>
#include <GLFW/glfw3.h>

#include <cuda.h>
#include <cuda_gl_interop.h>
#include <cuda_runtime_api.h>

#include <stdio.h>
#include <stdlib.h>

#include "gl_util.h"

// ------------------
// MARK: DECLARATIONS
// ------------------

#define M_EPSILON 0.00001f
#define DEGREES_TO_RAD(deg) ((deg / 180.0f) * M_PI)

#define MAX_ITER 10
#define WALL_SIZE 1.0f
#define FOV_DEGREES 90.0f
#define FOV DEGREES_TO_RAD(FOV_DEGREES)
#define DEPTH_FACTOR 5.0f

#define MAP_WIDTH 7
#define MAP_HEIGHT 7

__device__ int MAP[] = {
	1, 1, 1, 1, 1, 1, 1,
	1, 1, 1, 0, 0, 0, 1,
	1, 1, 0, 0, 0, 0, 1,
	1, 0, 0, 0, 0, 0, 1,
	1, 0, 0, 0, 0, 0, 1,
	1, 1, 0, 1, 0, 1, 1,
	1, 1, 1, 1, 1, 1, 1
};

const char * WINDOW_TITLE = "RayCaster - Cuda";
void present_gl();

// -----------------
// MARK: DEVICE CODE
// -----------------

/** Given RGB input on a [0.0,1.0] scale, create a color which we can output.  */
__device__ uchar4 make_color(float r, float g, float b) {
	return make_uchar4(r * 255, g * 255, b * 255, 255);
}

/** Computes the magnitude of the input vector. */
__device__ float mag(float2 v) {
	return sqrt(v.x * v.x + v.y * v.y);
}

/** Normalize the input vector. */
__device__ float2 normalize(float2 v) {
	const float M = mag(v);
	return make_float2(v.x / M, v.y / M);
}

/** Compute the vector dot product of the two input vectors. */
__device__ float dot(float2 v0, float2 v1) {
	return v0.x * v1.x + v0.y * v1.y;
}

/** Compute the distance between two vectors. */
__device__ float dist(float2 v0, float2 v1) {
	return sqrt(pow(v0.x - v1.x, 2) + pow(v0.y - v1.y, 2));
}

/** Rotate the input vector by the given angle 'r' in radians. */
__device__ float2 rotate(float2 v, float r) {
	return make_float2(
		dot(v, make_float2(cos(r), -sin(r))),
		dot(v, make_float2(sin(r), cos(r)))
	);
}

/** Sample the MAP[] array for the given position. */
__device__ int sample_map(float2 pos) {
	int x = (int)(pos.x / WALL_SIZE);
	int y = (int)(pos.y / WALL_SIZE);

	if (x >= MAP_WIDTH || x < 0 || y >= MAP_HEIGHT || y < 0) { return 1; }

	return MAP[MAP_WIDTH * y + x];
}

surface<void, 2> tex;
__global__ void runCuda(float time, unsigned screen_w, unsigned screen_h) {
	unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;
	unsigned int y = blockIdx.y * blockDim.y + threadIdx.y;

	// don't do any off screen work
	// and certainly don't write off the texture buffer
	if (x >= screen_w || y >= screen_h) { return; }

	const float2 P = make_float2(MAP_WIDTH * 0.5f, MAP_HEIGHT * 0.5f);
	float2 look = normalize(make_float2(1.0f, 1.0f));
	look = rotate(look, 0.5f * time * M_PI);
	look = rotate(look, FOV * (x / (float)screen_w - 0.5));

	float2 pos = P;
	for (int iter = 0; iter < MAX_ITER && sample_map(pos) == 0; iter++) {
		// distance to the nearest wall on each dimension
		float x_dist = (look.x > 0.0f ? ceil(pos.x) : floor(pos.x)) - pos.x;
		float y_dist = (look.y > 0.0f ? ceil(pos.y) : floor(pos.y)) - pos.y;

		// move a smidge more than necessary to guarantee 
		// we actually moved to a new region
		x_dist += (look.x > 0.0f ? M_EPSILON : -M_EPSILON) * WALL_SIZE;
		y_dist += (look.y > 0.0f ? M_EPSILON : -M_EPSILON) * WALL_SIZE;

		// how 'long' will it take to reach that wall?
		float tx = abs(x_dist / look.x);
		float ty = abs(y_dist / look.y);
		float t = min(tx, ty);

		// move to the nearest wall using the look vector
		pos.x += t * look.x;
		pos.y += t * look.y;
	}

	// pos is now the furthest wall from the users position
	// compute the distance of that wall
	const float d = dist(pos, P);

	// the height (in pixels) of the wall we hit
	const float H = screen_h * max(1.0 - (d / DEPTH_FACTOR), 0.0f);

	// float g = (d-1.5f); /* debug greyscale output */
	uchar4 data = make_color(0.0f, 0.0f, 0.0f);

	// check if the current y position should render for the hit wall height
	if (y > (screen_h - H) * 0.5f && y < (screen_h + H) * 0.5f) {
		data = make_color(1.0f, 1.0f, 1.0f);
	}

	surf2Dwrite<uchar4>(data, tex, x * sizeof(uchar4), y);
}

// -------------------------------------
// MARK: WINDOW SETUP & LIFETIME METHODS
// -------------------------------------

void check_err(cudaError_t err) {
	if (err != cudaSuccess) {
		fprintf(stderr, "%s\n", cudaGetErrorString(err));
		exit(0);
	}
}

int main() {
	init_gl(WINDOW_TITLE, VSYNC_ENABLED);

	struct cudaGraphicsResource * tex_res;
	struct cudaArray * cu_arr;

	cudaSetDevice(0);
	cudaGLSetGLDevice(0);
	cudaGraphicsGLRegisterImage(&tex_res, screen_tex, GL_TEXTURE_2D, 
			cudaGraphicsRegisterFlagsSurfaceLoadStore);
	cudaGraphicsMapResources(1, &tex_res, 0);
	cudaGraphicsSubResourceGetMappedArray(&cu_arr, tex_res, 0, 0);
	cudaBindSurfaceToArray(tex, cu_arr);

	// Game loop.
	glfwSetTime(0.0f);
	while (!glfwWindowShouldClose(window)) {
		// Close on escape press.
		if (glfwGetKey(window, GLFW_KEY_ESCAPE) == GLFW_PRESS) {
			glfwSetWindowShouldClose(window, GL_TRUE);
		}

		// Run our CUDA kernel to generate the image.
		dim3 block(8, 8);
		dim3 grid((screen_w + block.x - 1) / block.x,
				  (screen_h + block.y - 1) / block.y);
		float time = glfwGetTime() / 5.0f;
		runCuda<<<grid, block>>>(time, screen_w, screen_h);
		cudaGraphicsUnmapResources(1, &tex_res, 0);
		cudaStreamSynchronize(0);

		present_gl();
		glfwSwapBuffers(window);
		glfwPollEvents();
	}

	// Done - cleanup
	cudaGraphicsUnregisterResource(tex_res);
	glfwTerminate();
	return 0;
}

/**
 * Push a new frame to the screen.
 * This will contain the 'screen_tex' managed by gl_util.
 */
void present_gl() {
	glClearColor(0, 0, 0, 1);
	glClear(GL_COLOR_BUFFER_BIT);
	update_screen();
}
