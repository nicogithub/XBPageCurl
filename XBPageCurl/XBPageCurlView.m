//
//  XBPageCurlView.m
//  XBPageCurl
//
//  Created by xiss burg on 8/21/11.
//  Copyright 2011 __MyCompanyName__. All rights reserved.
//

#import "XBPageCurlView.h"
#import <QuartzCore/QuartzCore.h>


typedef struct _Vertex
{
    GLfloat x, y, z;
    GLfloat u, v;
    GLubyte color[4];
} Vertex;

void OrthoM4x4(GLfloat *out, GLfloat left, GLfloat right, GLfloat bottom, GLfloat top, GLfloat near, GLfloat far);
void MultiplyM4x4(const GLfloat *A, const GLfloat *B, GLfloat *out);
CGContextRef CreateARGBBitmapContext (size_t pixelsWide, size_t pixelsHigh);


@interface XBPageCurlView ()

@property (nonatomic, retain) EAGLContext *context;
@property (nonatomic, retain) CADisplayLink *displayLink;

- (void)createFramebuffer;
- (void)destroyFramebuffer;
- (void)createBuffersWithXRes:(GLuint)xRes yRes:(GLuint)yRes;
- (void)destroyBuffers;
- (BOOL)setupShaders;
- (void)setupMVP;
- (void)createTextureFromView:(UIView *)view;
- (void)startAnimating;
- (void)stopAnimating;
- (void)draw:(CADisplayLink *)sender;

@end


@implementation XBPageCurlView

@synthesize context=_context, displayLink=_displayLink;

- (BOOL)initialize
{
    CAEAGLLayer *layer = (CAEAGLLayer *)self.layer;
    layer.opaque = YES;
    layer.drawableProperties = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:NO], kEAGLDrawablePropertyRetainedBacking, kEAGLColorFormatRGBA8, kEAGLDrawablePropertyColorFormat, nil];
    
    _context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    
    if (_context == nil || [EAGLContext setCurrentContext:self.context] == NO) {
        return NO;
    }
    
    if (![self setupShaders]) {
        return NO;
    }
    
    if ([[UIScreen mainScreen] respondsToSelector:@selector(scale)]) {
        [self setContentScaleFactor:[[UIScreen mainScreen] scale]];
    }
    
    cylinderPosition = CGPointMake(260, 50);
    cylinderDirection = CGPointMake(cosf(M_PI/3), sinf(M_PI/3));
    cylinderRadius = 32;
    startPickingPosition = CGPointMake(self.bounds.size.width, 0);
    
    return YES;
}

- (id)initWithView:(UIView *)view
{
    CGRect frame = CGRectMake(0, 0, view.bounds.size.width, view.bounds.size.height);
    self = [super initWithFrame:frame];
    if (self) {
        if (![self initialize]) {
            [self release];
            return nil;
        }
        
        [self createTextureFromView:view];
    }
    return self;
}

- (void)dealloc
{
    self.context = nil;
    self.displayLink = nil;
    [self destroyBuffers];
    [super dealloc];
}


#pragma mark - Overrides

+ (Class)layerClass 
{
    return [CAEAGLLayer class];
}

- (void)layoutSubviews
{
    [EAGLContext setCurrentContext:self.context];
    [self destroyFramebuffer];
    [self createFramebuffer];
}


#pragma mark - Methods

- (void)createFramebuffer
{
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    
    glGenRenderbuffers(1, &colorRenderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, colorRenderbuffer);
    [self.context renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer *)self.layer];
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, colorRenderbuffer);
    
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &viewportWidth);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &viewportHeight);
    
    glGenRenderbuffers(1, &depthRenderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, depthRenderbuffer);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, viewportWidth, viewportHeight);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depthRenderbuffer);
    
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        NSLog(@"Failed to create framebuffer: %x", status);
    }
    
    //Create multisampling buffers
    glGenFramebuffers(1, &sampleFramebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, sampleFramebuffer);
    
    glGenRenderbuffers(1, &sampleColorRenderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, sampleColorRenderbuffer);
    glRenderbufferStorageMultisampleAPPLE(GL_RENDERBUFFER, 4, GL_RGBA8_OES, viewportWidth, viewportHeight);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, sampleColorRenderbuffer);
    
    glGenRenderbuffers(1, &sampleDepthRenderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, sampleDepthRenderbuffer);
    glRenderbufferStorageMultisampleAPPLE(GL_RENDERBUFFER, 4, GL_DEPTH_COMPONENT16, viewportWidth, viewportHeight);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, sampleDepthRenderbuffer);
    
    status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        NSLog(@"Failed to create multisamping framebuffer: %x", status);
    }
    
    [self setupMVP];
    [self createBuffersWithXRes:80 yRes:120];
    [self startAnimating];
}

- (void)destroyFramebuffer
{
    glDeleteFramebuffers(1, &framebuffer);
    framebuffer = 0;
    
    glDeleteRenderbuffers(1, &colorRenderbuffer);
    colorRenderbuffer = 0;
    
    glDeleteRenderbuffers(1, &depthRenderbuffer);
    depthRenderbuffer = 0;
}

- (void)createBuffersWithXRes:(GLuint)xRes yRes:(GLuint)yRes
{
    GLsizeiptr verticesSize = (xRes+1)*(yRes+1)*sizeof(Vertex);
    Vertex *vertices = malloc(verticesSize);
    
    GLubyte (^RandomByte)(void) = ^(void) {
        return (GLubyte)(((double)arc4random()/((1LL<<32)-1))*255);
    };
    
    for (int y=0; y<yRes+1; ++y) {
        GLfloat vy = ((GLfloat)y/yRes)*viewportHeight;
        GLfloat tv = vy;///viewportHeight;
        for (int x=0; x<xRes+1; ++x) {
            Vertex *v = &vertices[y*(xRes+1) + x];
            v->x = ((GLfloat)x/xRes)*viewportWidth;
            v->y = vy;
            v->z = 0;
            v->u = v->x;///viewportWidth;
            v->v = tv;
            v->color[0] = RandomByte();
            v->color[1] = RandomByte();
            v->color[2] = RandomByte();
            v->color[3] = 255;
        }
    }
    
    elementCount = xRes*yRes*2*3;
    GLsizeiptr indicesSize = elementCount*sizeof(GLushort);//Two triangles per square, 3 indices per triangle
    GLushort *indices = malloc(indicesSize);
    
    for (int y=0; y<yRes; ++y) {
        for (int x=0; x<xRes; ++x) {
            int i = y*(xRes+1) + x;
            int idx = y*xRes + x;
            assert(i < elementCount*3-1);
            indices[idx*6+0] = i;
            indices[idx*6+1] = i + 1;
            indices[idx*6+2] = i + xRes + 1;
            indices[idx*6+3] = i + 1;
            indices[idx*6+4] = i + xRes + 2;
            indices[idx*6+5] = i + xRes + 1;
        }
    }
    
    glGenBuffers(1, &vertexBuffer);
    glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer);
    glBufferData(GL_ARRAY_BUFFER, verticesSize, (GLvoid *)vertices, GL_STATIC_DRAW);
    
    glGenBuffers(1, &indexBuffer);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, indexBuffer);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, indicesSize, (GLvoid *)indices, GL_STATIC_DRAW);
    
    free(vertices);
    free(indices);
}

- (void)destroyBuffers
{
    glDeleteBuffers(1, &vertexBuffer);
    glDeleteBuffers(1, &indexBuffer);
    vertexBuffer = indexBuffer = 0;
}

- (void)setupMVP
{
    OrthoM4x4(mvp, 0.f, viewportWidth, 0.f, viewportHeight, -1000.f, 1000.f);
}

- (GLuint)loadShader:(NSString *)filename type:(GLenum)type 
{
    GLuint shader = glCreateShader(type);
    
    if (shader == 0) {
        return 0;
    }
    
    NSString *path = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:filename];
    NSString *shaderString = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    const GLchar *shaderSource = [shaderString cStringUsingEncoding:NSUTF8StringEncoding];
    
    glShaderSource(shader, 1, &shaderSource, NULL);
    glCompileShader(shader);
    
    GLint success = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &success);
    
    if (success == 0) {
        char errorMsg[2048];
        glGetShaderInfoLog(shader, sizeof(errorMsg), NULL, errorMsg);
        NSString *errorString = [NSString stringWithCString:errorMsg encoding:NSUTF8StringEncoding];
        NSLog(@"Failed to compile %@: %@", filename, errorString);
        glDeleteShader(shader);
        return 0;
    }
    
    return shader;
}

- (BOOL)setupShaders
{
    GLuint vertexShader = [self loadShader:@"VertexProgram.glsl" type:GL_VERTEX_SHADER];
    GLuint fragmentShader = [self loadShader:@"FragmentProgram.glsl" type:GL_FRAGMENT_SHADER];
    program = glCreateProgram();
    
    glAttachShader(program, vertexShader);
    glAttachShader(program, fragmentShader);
    glLinkProgram(program);
    
    GLint linked = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (linked == 0) {
        glDeleteProgram(program);
        return NO;
    }
    
    positionHandle          = glGetAttribLocation(program, "a_position");
    texCoordHandle          = glGetAttribLocation(program, "a_texCoord");
    colorHandle             = glGetAttribLocation(program, "a_color");
    mvpHandle               = glGetUniformLocation(program, "u_mvpMatrix");
    samplerHandle           = glGetUniformLocation(program, "s_tex");
    texSizeHandle           = glGetUniformLocation(program, "u_texSize");
    cylinderPositionHandle  = glGetUniformLocation(program, "u_cylinderPosition");
    cylinderDirectionHandle = glGetUniformLocation(program, "u_cylinderDirection");
    cylinderRadiusHandle    = glGetUniformLocation(program, "u_cylinderRadius");
    
    return YES;
}

- (void)createTextureFromView:(UIView *)view
{
    /*
    NSString *imagePath = [[NSBundle mainBundle] pathForResource:@"appleStore" ofType:@"png"];
    UIImage *image = [UIImage imageWithContentsOfFile:imagePath];
    CGImageRef imageRef = image.CGImage;
    
    size_t imageWidth = CGImageGetWidth(imageRef);
    size_t imageHeight = CGImageGetHeight(imageRef);
     */
    
    //Compute the actual view size in the current screen scale
    CGSize actualViewSize = view.bounds.size;
    
    if ([[UIScreen mainScreen] respondsToSelector:@selector(scale)] && [[UIScreen mainScreen] scale] == 2) {
        actualViewSize = CGSizeMake(view.bounds.size.width*2, view.bounds.size.height*2);
    }
    
    //Compute the closest, greater power of two
    CGFloat textureWidth = 1<<((int)floorf(log2f(actualViewSize.width)) + 1);
    CGFloat textureHeight = 1<<((int)floorf(log2f(actualViewSize.height)) + 1);
    
    if (textureWidth < 64) {
        textureWidth = 64;
    }
    
    if (textureHeight < 64) {
        textureHeight = 64;
    }
    
    //Set shader texture scale
    glUseProgram(program);
    glUniform2f(texSizeHandle, textureWidth, textureHeight);
    glUseProgram(0);
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    NSUInteger bytesPerPixel = 4;
    NSUInteger bitsPerChannel = 8;
    NSUInteger bytesPerRow = bytesPerPixel * textureWidth;
    GLubyte *textureData = malloc(textureWidth * textureHeight * bytesPerPixel * sizeof(GLubyte));
    int pattern = 0xff7f7f7f;
    memset_pattern4(textureData, &pattern, textureWidth * textureHeight * bytesPerPixel);
    CGContextRef bitmapContext = CGBitmapContextCreate(textureData, textureWidth, textureHeight, bitsPerChannel, bytesPerRow, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextTranslateCTM(bitmapContext, 0, textureHeight-view.layer.bounds.size.height);
    [view.layer renderInContext:bitmapContext];
    
    CGContextRelease(bitmapContext);
    
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, textureWidth, textureHeight, 0, GL_RGBA, GL_UNSIGNED_BYTE, textureData);
    glBindTexture(GL_TEXTURE_2D, 0);
  
    free(textureData);
}

- (void)startAnimating
{
    [self.displayLink invalidate];
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(draw:)];
    [self.displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
}

- (void)stopAnimating
{
    [self.displayLink invalidate];
    self.displayLink = nil;
}

- (void)draw:(CADisplayLink *)sender
{    
    [EAGLContext setCurrentContext:self.context];
    
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glViewport(0, 0, viewportWidth, viewportHeight);
    
    glClearColor(0.4, 0.4, 0.4, 1);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    
    //glEnable(GL_BLEND);
    //glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    
    glUseProgram(program);
    
    glDisable(GL_CULL_FACE);
    glEnable(GL_DEPTH_TEST);
    
    glUniform2f(cylinderPositionHandle, cylinderPosition.x, cylinderPosition.y);
    glUniform2f(cylinderDirectionHandle, cylinderDirection.x, cylinderDirection.y);
    glUniform1f(cylinderRadiusHandle, cylinderRadius);
    
    glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer);
    glVertexAttribPointer(positionHandle, 3, GL_FLOAT, GL_FALSE, sizeof(Vertex), (void *)offsetof(Vertex, x));
    glEnableVertexAttribArray(positionHandle);
    glVertexAttribPointer(texCoordHandle, 2, GL_FLOAT, GL_FALSE, sizeof(Vertex), (void *)offsetof(Vertex, u));
    glEnableVertexAttribArray(texCoordHandle);
    glVertexAttribPointer(colorHandle, 4, GL_UNSIGNED_BYTE, GL_TRUE, sizeof(Vertex), (void *)offsetof(Vertex, color));
    glEnableVertexAttribArray(colorHandle);
    glUniformMatrix4fv(mvpHandle, 1, GL_FALSE, mvp);
    
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texture);
    glUniform1i(samplerHandle, 0);
    
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, indexBuffer);
    glDrawElements(GL_TRIANGLES, elementCount, GL_UNSIGNED_SHORT, (void *)0);
    /*
    glBindFramebuffer(GL_READ_FRAMEBUFFER_APPLE, sampleFramebuffer);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER_APPLE, framebuffer);
    glResolveMultisampleFramebufferAPPLE();
    */
    glBindRenderbuffer(GL_RENDERBUFFER, colorRenderbuffer);
    [self.context presentRenderbuffer:GL_RENDERBUFFER];
    
    GLenum error = glGetError();
    if (error != GL_NO_ERROR) {
        NSLog(@"%d", error);
    }
}


#pragma mark - Touch handling

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
    [super touchesBegan:touches withEvent:event];
    startPickingPosition = [[touches anyObject] locationInView:self];
    startPickingPosition.x = self.bounds.size.width;
    startPickingPosition.y = self.bounds.size.height - startPickingPosition.y;
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
    [super touchesMoved:touches withEvent:event];
    cylinderPosition = [[touches anyObject] locationInView:self];
    cylinderPosition.y = self.bounds.size.height - cylinderPosition.y;
    CGPoint dir = CGPointMake(startPickingPosition.x-cylinderPosition.x, startPickingPosition.y-cylinderPosition.y);
    dir = CGPointMake(-dir.y, dir.x);
    CGFloat length = sqrtf(dir.x*dir.x + dir.y*dir.y);
    dir.x /= length, dir.y /= length;
    cylinderDirection = dir;
    
    cylinderRadius = 6 + length/4;
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
    [super touchesEnded:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
    [super touchesCancelled:touches withEvent:event];
}

@end


#pragma mark - Functions

void MultiplyM4x4(const GLfloat *A, const GLfloat *B, GLfloat *out)
{
    for (int i=0; i<4; ++i) {
        for (int j=0; j<4; ++j) {
            GLfloat f = 0.f;
            for (int k=0; k<4; ++k) {
                f += A[i*4+k] * B[k*4+j];
            }
            out[i*4+j] = f;
        }
    }
}

void OrthoM4x4(GLfloat *out, GLfloat left, GLfloat right, GLfloat bottom, GLfloat top, GLfloat near, GLfloat far)
{
    out[0] = 2.f/(right-left); out[4] = 0.f; out[8] = 0.f; out[12] = -(right+left)/(right-left);
    out[1] = 0.f; out[5] = 2.f/(top-bottom); out[9] = 0.f; out[13] = -(top+bottom)/(top-bottom);
    out[2] = 0.f; out[6] = 0.f; out[10] = -2.f/(far-near); out[14] = -(far+near)/(far-near);
    out[3] = 0.f; out[7] = 0.f; out[11] = 0.f; out[15] = 1.f;
}

CGContextRef CreateARGBBitmapContext (size_t pixelsWide, size_t pixelsHigh)
{
    CGContextRef    context = NULL;
    CGColorSpaceRef colorSpace;
    void *          bitmapData;
    int             bitmapByteCount;
    int             bitmapBytesPerRow;
    
    // Get image width, height. We'll use the entire image.
    //size_t pixelsWide = CGImageGetWidth(inImage);
    //size_t pixelsHigh = CGImageGetHeight(inImage);
    
    // Declare the number of bytes per row. Each pixel in the bitmap in this
    // example is represented by 4 bytes; 8 bits each of red, green, blue, and
    // alpha.
    bitmapBytesPerRow   = (pixelsWide * 4);
    bitmapByteCount     = (bitmapBytesPerRow * pixelsHigh);
    
    // Use the generic RGB color space.
    colorSpace = CGColorSpaceCreateDeviceRGB();
    if (colorSpace == NULL)
    {
        fprintf(stderr, "Error allocating color space\n");
        return NULL;
    }
    
    // Allocate memory for image data. This is the destination in memory
    // where any drawing to the bitmap context will be rendered.
    bitmapData = malloc( bitmapByteCount );
    if (bitmapData == NULL) 
    {
        fprintf (stderr, "Memory not allocated!");
        CGColorSpaceRelease( colorSpace );
        return NULL;
    }
    
    // Create the bitmap context. We want pre-multiplied ARGB, 8-bits 
    // per component. Regardless of what the source image format is 
    // (CMYK, Grayscale, and so on) it will be converted over to the format
    // specified here by CGBitmapContextCreate.
    context = CGBitmapContextCreate (bitmapData,
                                     pixelsWide,
                                     pixelsHigh,
                                     8,      // bits per component
                                     bitmapBytesPerRow,
                                     colorSpace,
                                     kCGImageAlphaPremultipliedFirst);
    if (context == NULL)
    {
        free (bitmapData);
        fprintf (stderr, "Context not created!");
    }
    
    // Make sure and release colorspace before returning
    CGColorSpaceRelease( colorSpace );
    
    return context;
}
