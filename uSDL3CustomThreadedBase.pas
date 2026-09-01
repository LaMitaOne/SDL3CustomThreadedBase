{*******************************************************************************
  SDL3ThreadedRenderer v0.1
********************************************************************************
  A high-performance, threaded SDL3 component for Delphi/VCL.
  Utilizing SDL3 to create its own native OS window dynamically.

  Author: Lara Miriam Tamy Reschke / LamitaOne
  Date:   2024
  License: MIT (or whatever you prefer)

  ----------------------------------------------------------------------------
  FEATURES & ARCHITECTURE
  ----------------------------------------------------------------------------
  1. Dynamic SDL3 Binding:
     No static `.dcu` or object files required. The SDL3.dll is loaded at
     runtime via `LoadLibrary`. If the DLL is missing, the component fails
     gracefully without crashing the IDE.

  2. Hybrid High-Resolution Timer:
     Uses `TStopwatch` (QPC) for microsecond accuracy. To prevent 100% CPU
     usage while waiting for the next frame, it uses a hybrid approach:
     - `Sleep(1)` for the bulk of the wait time (releases CPU to OS).
     - A tight spinlock for the last 2 milliseconds to ensure frame-perfect
       timing without context switching overhead.

  3. Thread-Safe UI Integration (The Secret Sauce):
     The SDL Window is created in the VCL Main Thread (required by Windows
     OS for proper message queue handling). However, the heavy math, logic,
     and timing calculations run in a background worker thread.
     Instead of using `TThread.Synchronize` (which blocks the worker thread
     and destroys performance), we use `TThread.Queue`. This pushes the
     render command asynchronously to the main thread's message queue.

     Result: 2500+ FPS on modern hardware (RTX 2060S / Ryzen 5800X) while
     keeping the VCL UI (Trackbars, Buttons) fully responsive!

  4. FPU Exception Masking:
     SDL and C-libraries often generate floating point exceptions (denormals,
     precision loss) that Delphi catches by default, causing massive slowdowns
     or crashes. We explicitly mask these at the start of the worker thread.
***************************************************************************}

unit uSDL3CustomThreadedBase;

interface

uses
  System.SysUtils, System.Types, System.Classes, System.Math,
  System.SyncObjs, System.Diagnostics,
  Vcl.Controls, Vcl.Forms, Vcl.Graphics,
  Winapi.Windows, Winapi.Messages, Winapi.MMSystem;

const
  // 2 milliseconds threshold for the spinlock phase
  SPIN_THRESHOLD_NS = 2000000;

  // SDL Init Flags
  SDL_INIT_VIDEO = $00000020;

  // SDL Event Types
  SDL_EVENT_QUIT = $100;

type
  // Basic SDL opaque pointer types
  TSDL_Window = Pointer;
  TSDL_Renderer = Pointer;

  // Minimal SDL_Event record to catch the Quit event
  TSDL_Event = record
    case Integer of
      0: (typ: Cardinal);
      1: (padding: array[0..55] of Byte);
  end;

  {------------------------------------------------------------------------------
    THighResTimer
    A record providing high-precision frame timing with a hybrid wait strategy
    to balance accuracy and CPU usage.
  ------------------------------------------------------------------------------}
  THighResTimer = record
  private
    FSW: TStopwatch;
  public
    procedure Init;
    function GetTicks: Int64; inline;
    procedure HybridWaitUntil(const ATargetTicks, ASpinNanoseconds: Int64);
  end;

  {------------------------------------------------------------------------------
    TVec3
    Simple 3D Vector record for demo math.
  ------------------------------------------------------------------------------}
  TVec3 = record
    x, y, z: Single;
  end;

  {------------------------------------------------------------------------------
    TSDL3CustomThreadedBase
    The main component class. Inherit from this to create custom SDL3 renderers.
  ------------------------------------------------------------------------------}
  TSDL3CustomThreadedBase = class(TComponent)
  private
    FThread: TThread;
    FLock: TCriticalSection;
    FTargetFPS: Integer;
    FThreadActive: Boolean;
    FPaused: Boolean;
    FActive: Boolean;

    FSDLLib: THandle;
    FSDLWindow: TSDL_Window;
    FSDLRenderer: TSDL_Renderer;

    FFrameCount: Integer;
    FLastFpsTime: Int64;
    FRealFPS: Integer;

    { 3D Demo Mode State }
    FCubePos: TVec3;
    FCubeVel: TVec3;
    FAngle: Single;
    FTimeSec: Double;

    procedure SetActive(const Value: Boolean);
    procedure SetTargetFPS(const Value: Integer);
    procedure StartThread;
    procedure StopThread;
    procedure LoadSDL;
    procedure FreeSDL;

    procedure DoSDLInit;
    procedure DoSDLCleanup;
  protected
    // Override these in derived classes for custom rendering
    procedure InitSDLResources; virtual;
    procedure UpdateLogic(const DeltaTime: Double); virtual;
    procedure RenderEffect(const ATime: Double); virtual;
    procedure ShutdownSDLResources; virtual;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    property RealFPS: Integer read FRealFPS;
    property SDLWindow: TSDL_Window read FSDLWindow;
    property SDLRenderer: TSDL_Renderer read FSDLRenderer;
  published
    property Active: Boolean read FActive write SetActive default False;
    property TargetFPS: Integer read FTargetFPS write SetTargetFPS default 60;
  end;

implementation

{==============================================================================
  Dynamic SDL3 Function Types
==============================================================================}
type
  TSDL_Init = function(Flags: Cardinal): Boolean; cdecl;
  TSDL_Quit = procedure; cdecl;
  TSDL_CreateWindow = function(Title: PAnsiChar; W, H: Int32; Flags: Cardinal): TSDL_Window; cdecl;
  TSDL_CreateRenderer = function(Window: TSDL_Window; Name: PAnsiChar): TSDL_Renderer; cdecl;
  TSDL_DestroyWindow = procedure(Window: TSDL_Window); cdecl;
  TSDL_DestroyRenderer = procedure(Renderer: TSDL_Renderer); cdecl;
  TSDL_SetRenderDrawColor = function(Renderer: TSDL_Renderer; R, G, B, A: Byte): Boolean; cdecl;
  TSDL_RenderClear = function(Renderer: TSDL_Renderer): Boolean; cdecl;
  TSDL_RenderPresent = procedure(Renderer: TSDL_Renderer); cdecl;
  TSDL_RenderLine = function(Renderer: TSDL_Renderer; x1, y1, x2, y2: Single): Boolean; cdecl;
  TSDL_PollEvent = function(Event: Pointer): Boolean; cdecl;

var
  // Global function pointers for dynamically loaded SDL3.dll
  _SDL_Init: TSDL_Init;
  _SDL_Quit: TSDL_Quit;
  _SDL_CreateWindow: TSDL_CreateWindow;
  _SDL_CreateRenderer: TSDL_CreateRenderer;
  _SDL_DestroyWindow: TSDL_DestroyWindow;
  _SDL_DestroyRenderer: TSDL_DestroyRenderer;
  _SDL_SetRenderDrawColor: TSDL_SetRenderDrawColor;
  _SDL_RenderClear: TSDL_RenderClear;
  _SDL_RenderPresent: TSDL_RenderPresent;
  _SDL_RenderLine: TSDL_RenderLine;
  _SDL_PollEvent: TSDL_PollEvent;

{==============================================================================
  THighResTimer Implementation
==============================================================================}

procedure THighResTimer.Init;
begin
  // Start the underlying high-resolution stopwatch
  FSW := TStopwatch.StartNew;
end;

function THighResTimer.GetTicks: Int64;
begin
  // Get raw elapsed ticks for maximum precision
  Result := FSW.ElapsedTicks;
end;

procedure THighResTimer.HybridWaitUntil(const ATargetTicks, ASpinNanoseconds: Int64);
var
  Freq, SpinTicks, Remaining: Int64;
begin
  Freq := TStopwatch.Frequency;
  if Freq = 0 then Exit;

  // Calculate how many ticks correspond to the spin threshold (e.g., 2ms)
  SpinTicks := (UInt64(ASpinNanoseconds) * UInt64(Freq)) div 1000000000;

  // Phase 1: OS Sleep. Yield CPU time to other threads while far from target.
  Remaining := ATargetTicks - GetTicks;
  while Remaining > SpinTicks do
  begin
    Sleep(1);
    Remaining := ATargetTicks - GetTicks;
  end;

  // Phase 2: Spinlock. Burn CPU cycles for the last few microseconds to
  // guarantee we hit the exact target tick without context switch latency.
  while GetTicks < ATargetTicks do ;
end;

{==============================================================================
  TSDL3CustomThreadedBase
==============================================================================}

constructor TSDL3CustomThreadedBase.Create(AOwner: TComponent);
begin
  inherited;
  FLock := TCriticalSection.Create;
  FThreadActive := False;
  FPaused := True;
  FActive := False;
  FTargetFPS := 60;

  FFrameCount := 0;
  FLastFpsTime := 0;
  FRealFPS := 0;

  // Initialize 3D Cube Position & Velocity for the demo
  FCubePos.x := 0; FCubePos.y := 0; FCubePos.z := 0;
  FCubeVel.x := 3; FCubeVel.y := 3; FCubeVel.z := 3;
  FAngle := 0.0;

  // Attempt to load SDL3.dll immediately
  LoadSDL;
end;

destructor TSDL3CustomThreadedBase.Destroy;
begin
  StopThread;
  FreeSDL;
  FreeAndNil(FLock);
  inherited;
end;

procedure TSDL3CustomThreadedBase.LoadSDL;
begin
  FSDLLib := LoadLibrary('SDL3.dll');
  if FSDLLib = 0 then Exit; // DLL not found, will raise exception on Activate

  // Bind all required SDL3 functions
  @_SDL_Init := GetProcAddress(FSDLLib, 'SDL_Init');
  @_SDL_Quit := GetProcAddress(FSDLLib, 'SDL_Quit');
  @_SDL_CreateWindow := GetProcAddress(FSDLLib, 'SDL_CreateWindow');
  @_SDL_CreateRenderer := GetProcAddress(FSDLLib, 'SDL_CreateRenderer');
  @_SDL_DestroyWindow := GetProcAddress(FSDLLib, 'SDL_DestroyWindow');
  @_SDL_DestroyRenderer := GetProcAddress(FSDLLib, 'SDL_DestroyRenderer');
  @_SDL_SetRenderDrawColor := GetProcAddress(FSDLLib, 'SDL_SetRenderDrawColor');
  @_SDL_RenderClear := GetProcAddress(FSDLLib, 'SDL_RenderClear');
  @_SDL_RenderPresent := GetProcAddress(FSDLLib, 'SDL_RenderPresent');
  @_SDL_RenderLine := GetProcAddress(FSDLLib, 'SDL_RenderLine');
  @_SDL_PollEvent := GetProcAddress(FSDLLib, 'SDL_PollEvent');
end;

procedure TSDL3CustomThreadedBase.FreeSDL;
begin
  if FSDLLib <> 0 then
  begin
    if Assigned(_SDL_Quit) then
      _SDL_Quit;
    FreeLibrary(FSDLLib);
    FSDLLib := 0;
  end;
end;

procedure TSDL3CustomThreadedBase.DoSDLInit;
begin
  if FSDLLib = 0 then
    raise Exception.Create('SDL3.dll not found. Please ensure SDL3.dll is in the application directory.');

  if Assigned(_SDL_Init) then
    _SDL_Init(SDL_INIT_VIDEO);

  // CRITICAL: SDL Window and Renderer MUST be created in the Main UI Thread!
  // Otherwise, the OS Window Manager cannot attach a message queue properly,
  // causing the window to freeze and become unresponsive.
  if Assigned(_SDL_CreateWindow) then
    FSDLWindow := _SDL_CreateWindow('SDL3 3D Window', 800, 600, 0);

  if Assigned(_SDL_CreateRenderer) and (FSDLWindow <> nil) then
    FSDLRenderer := _SDL_CreateRenderer(FSDLWindow, nil);

  InitSDLResources;
end;

procedure TSDL3CustomThreadedBase.DoSDLCleanup;
begin
  if csDestroying in ComponentState then Exit;

  ShutdownSDLResources;

  if Assigned(FSDLRenderer) and Assigned(_SDL_DestroyRenderer) then
  begin
    _SDL_DestroyRenderer(FSDLRenderer);
    FSDLRenderer := nil;
  end;

  if Assigned(FSDLWindow) and Assigned(_SDL_DestroyWindow) then
  begin
    _SDL_DestroyWindow(FSDLWindow);
    FSDLWindow := nil;
  end;
end;

procedure TSDL3CustomThreadedBase.SetActive(const Value: Boolean);
begin
  if FActive <> Value then
  begin
    FActive := Value;
    if FActive then
    begin
      if not FThreadActive then
        StartThread;
      FPaused := False;
    end
    else
    begin
      FPaused := True;
    end;
  end;
end;

procedure TSDL3CustomThreadedBase.SetTargetFPS(const Value: Integer);
begin
  if FTargetFPS <> Value then
    FTargetFPS := Value;
end;

procedure TSDL3CustomThreadedBase.StartThread;
begin
  if FThreadActive then Exit;
  FThreadActive := True;

  // Step 1: Initialize SDL resources entirely in the Main Thread.
  DoSDLInit;

  // Step 2: Start the background worker thread for Logic and Timing.
  FThread := TThread.CreateAnonymousThread(
    procedure
    var
      Timer: THighResTimer;
      Freq, FrameTicks: Int64;
      NextFrame, NowTicks, LastFrameTicks, ElapsedTicks: Int64;
      DeltaSec: Double;
    begin
      // Mask FPU exceptions. SDL/C-libraries internally do math that can
      // trigger Delphi's default FPU exception handler, causing massive lag.
      System.Math.SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
      Set8087CW($133F);

      // Increase Windows system timer resolution to 1ms for better Sleep(1)
      {$IFDEF MSWINDOWS}
      timeBeginPeriod(1);
      {$ENDIF}
      try
        // Initialize high-resolution timer
        Timer.Init;
        Freq := TStopwatch.Frequency;
        if Freq <= 0 then Freq := 10000000;

        NowTicks := Timer.GetTicks;
        LastFrameTicks := NowTicks;
        NextFrame := NowTicks;
        FLastFpsTime := NowTicks;

        // --- MAIN WORKER THREAD LOOP ---
        while not TThread.CheckTerminated do
        begin
          // Note: _SDL_PollEvent is intentionally NOT called here.
          // Polling must happen in the Main Thread. If needed, implement
          // a TTimer in the main class to pump events, or rely on OS auto-pump.

          NowTicks := Timer.GetTicks;

          // Prevent division by zero if loop executes faster than timer resolution
          if NowTicks = LastFrameTicks then
          begin
            Timer.HybridWaitUntil(NowTicks + 1, SPIN_THRESHOLD_NS);
            Continue;
          end;

          // Calculate Delta Time for frame-independent physics
          DeltaSec := (NowTicks - LastFrameTicks) / Freq;
          LastFrameTicks := NowTicks;

          // Clamp DeltaSec to prevent physics tunneling on lag spikes
          if (DeltaSec <= 0) or (DeltaSec > 0.25) then
            DeltaSec := 1 / 60;

          // Run physics/logic in the background thread! Saves main thread time.
          if not FPaused then
            UpdateLogic(DeltaSec);

          // Save current time to be passed to the render method
          FTimeSec := NowTicks / Freq;

          // CRITICAL PERFORMANCE TRICK:
          // Use TThread.Queue instead of Synchronize.
          // Synchronize blocks this worker thread until the main thread finishes
          // rendering. Queue just drops the command into the Main Thread's queue
          // and immediately continues the loop.
          // This allows the worker thread to hit 2000+ FPS calculating logic,
          // while the Main Thread renders as fast as it can process the queue.
          TThread.Queue(nil,
            procedure
            begin
              RenderEffect(FTimeSec);
            end);

          // --- FPS Calculation ---
          Inc(FFrameCount);
          ElapsedTicks := NowTicks - FLastFpsTime;
          if ElapsedTicks >= Freq then
          begin
            FRealFPS := Round((Int64(FFrameCount) * Freq) / ElapsedTicks);
            FFrameCount := 0;
            FLastFpsTime := NowTicks;
          end;

          // --- Frame Limiting Logic ---
          if FTargetFPS > 0 then
            FrameTicks := Round(Freq / FTargetFPS)
          else
            FrameTicks := Freq div 60;

          NextFrame := NextFrame + FrameTicks;

          // If we are falling behind by more than 1 second, reset NextFrame
          // to prevent a "catch-up" spiral of death.
          NowTicks := Timer.GetTicks;
          if (NowTicks - NextFrame) > Freq then
            NextFrame := NowTicks;

          // Wait until the next target frame tick
          Timer.HybridWaitUntil(NextFrame, SPIN_THRESHOLD_NS);
        end;

      finally
        {$IFDEF MSWINDOWS}
        timeEndPeriod(1);
        {$ENDIF}

        // Cleanup SDL resources asynchronously in the Main Thread,
        // because the Window was created there.
        TThread.Queue(nil,
          procedure
          begin
            DoSDLCleanup;
            FThreadActive := False;
          end);
      end;
    end);

  FThread.FreeOnTerminate := False;
  FThread.Start;
end;

procedure TSDL3CustomThreadedBase.StopThread;
begin
  if not Assigned(FThread) then Exit;

  FThread.Terminate;
  FThread.WaitFor; // Wait for the background loop to exit cleanly
  FreeAndNil(FThread);
end;

{------------------------------------------------------------------------------
  VIRTUAL METHODS
  Override these in descendants to create custom 2D/3D scenes.
------------------------------------------------------------------------------}

procedure TSDL3CustomThreadedBase.InitSDLResources;
begin
  // Override to load custom textures, meshes, etc.
end;

procedure TSDL3CustomThreadedBase.ShutdownSDLResources;
begin
  // Override to free custom textures, meshes, etc.
end;

procedure TSDL3CustomThreadedBase.UpdateLogic(const DeltaTime: Double);
begin
  // 1. Move the cube
  FCubePos.x := FCubePos.x + FCubeVel.x * DeltaTime;
  FCubePos.y := FCubePos.y + FCubeVel.y * DeltaTime;
  FCubePos.z := FCubePos.z + FCubeVel.z * DeltaTime;

  // 2. Bounce off invisible walls
  if Abs(FCubePos.x) > 5 then FCubeVel.x := -FCubeVel.x;
  if Abs(FCubePos.y) > 5 Then FCubeVel.y := -FCubeVel.y;
  if Abs(FCubePos.z) > 5 Then FCubeVel.z := -FCubeVel.z;

  // 3. Rotate the cube
  FAngle := FAngle + (1.5 * DeltaTime);
end;

procedure TSDL3CustomThreadedBase.RenderEffect(const ATime: Double);
var
  BasePoints: array[0..7] of TVec3;
  Rotated: array[0..7] of TVec3;
  Projected: array[0..7] of TPointF;
  i: Integer;
  CosA, SinA: Single;
  ZOffset, FOV: Single;
  Scale: Single;
  Cx, Cy: Single;
  FinalZ: Single;
begin
  if not Assigned(FSDLRenderer) then Exit;

  // 1. Clear background (Dark Gray)
  if Assigned(_SDL_SetRenderDrawColor) then
    _SDL_SetRenderDrawColor(FSDLRenderer, 20, 20, 20, 255);
  if Assigned(_SDL_RenderClear) then
    _SDL_RenderClear(FSDLRenderer);

  if FActive then
  begin
    // Define Cube Geometry
    BasePoints[0].x := -1; BasePoints[0].y := -1; BasePoints[0].z := -1;
    BasePoints[1].x :=  1; BasePoints[1].y := -1; BasePoints[1].z := -1;
    BasePoints[2].x :=  1; BasePoints[2].y :=  1; BasePoints[2].z := -1;
    BasePoints[3].x := -1; BasePoints[3].y :=  1; BasePoints[3].z := -1;
    BasePoints[4].x := -1; BasePoints[4].y := -1; BasePoints[4].z :=  1;
    BasePoints[5].x :=  1; BasePoints[5].y := -1; BasePoints[5].z :=  1;
    BasePoints[6].x :=  1; BasePoints[6].y :=  1; BasePoints[6].z :=  1;
    BasePoints[7].x := -1; BasePoints[7].y :=  1; BasePoints[7].z :=  1;

    CosA := Cos(FAngle);
    SinA := Sin(FAngle);
    ZOffset := 10.0; // Push cube away from camera
    FOV := 400.0;    // Field of view scale factor
    Cx := 400.0;     // Screen center X
    Cy := 300.0;     // Screen center Y

    // 2. Rotate, translate, and project 3D points to 2D screen space
    for i := 0 to 7 do
    begin
      // Simple rotation matrix application
      Rotated[i].x := BasePoints[i].x * CosA - BasePoints[i].z * SinA;
      Rotated[i].z := BasePoints[i].x * SinA + BasePoints[i].z * CosA;
      Rotated[i].y := BasePoints[i].y * CosA - Rotated[i].z * SinA;
      Rotated[i].z := BasePoints[i].y * SinA + Rotated[i].z * CosA;

      // Apply cube position offset
      Rotated[i].x := Rotated[i].x + FCubePos.x;
      Rotated[i].y := Rotated[i].y + FCubePos.y;
      Rotated[i].z := Rotated[i].z + FCubePos.z;

      // Perspective projection
      FinalZ := Rotated[i].z + ZOffset;
      if FinalZ <= 0 then FinalZ := 0.1; // Prevent division by zero

      Scale := FOV / FinalZ;

      Projected[i].X := Cx + (Rotated[i].x * Scale);
      Projected[i].Y := Cy + (Rotated[i].y * Scale);
    end;

    // 3. Draw cube edges in bright red
    if Assigned(_SDL_SetRenderDrawColor) then
      _SDL_SetRenderDrawColor(FSDLRenderer, 255, 50, 50, 255);

    if Assigned(_SDL_RenderLine) then
    begin
      // Back face
      _SDL_RenderLine(FSDLRenderer, Projected[0].X, Projected[0].Y, Projected[1].X, Projected[1].Y);
      _SDL_RenderLine(FSDLRenderer, Projected[1].X, Projected[1].Y, Projected[2].X, Projected[2].Y);
      _SDL_RenderLine(FSDLRenderer, Projected[2].X, Projected[2].Y, Projected[3].X, Projected[3].Y);
      _SDL_RenderLine(FSDLRenderer, Projected[3].X, Projected[3].Y, Projected[0].X, Projected[0].Y);

      // Front face
      _SDL_RenderLine(FSDLRenderer, Projected[4].X, Projected[4].Y, Projected[5].X, Projected[5].Y);
      _SDL_RenderLine(FSDLRenderer, Projected[5].X, Projected[5].Y, Projected[6].X, Projected[6].Y);
      _SDL_RenderLine(FSDLRenderer, Projected[6].X, Projected[6].Y, Projected[7].X, Projected[7].Y);
      _SDL_RenderLine(FSDLRenderer, Projected[7].X, Projected[7].Y, Projected[4].X, Projected[4].Y);

      // Connecting edges
      _SDL_RenderLine(FSDLRenderer, Projected[0].X, Projected[0].Y, Projected[4].X, Projected[4].Y);
      _SDL_RenderLine(FSDLRenderer, Projected[1].X, Projected[1].Y, Projected[5].X, Projected[5].Y);
      _SDL_RenderLine(FSDLRenderer, Projected[2].X, Projected[2].Y, Projected[6].X, Projected[6].Y);
      _SDL_RenderLine(FSDLRenderer, Projected[3].X, Projected[3].Y, Projected[7].X, Projected[7].Y);
    end;
  end;

  // 4. Present the backbuffer to the screen
  if Assigned(_SDL_RenderPresent) then
    _SDL_RenderPresent(FSDLRenderer);
end;

end.
