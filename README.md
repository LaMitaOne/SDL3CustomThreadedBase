# SDL3CustomThreadedBase
A high-performance, multi-threaded SDL3 component for Delphi VCL. This component dynamically loads SDL3.dll at runtime to create its own native OS window, while keeping the VCL GUI (buttons, trackbars, panels) fully responsive and butter-smooth.

**SDL3CustomThreadedBase v0.1**
     
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/LaMitaOne/SDL3CustomThreadedBase)    
      
<img width="818" height="754" alt="Unbenannt" src="https://github.com/user-attachments/assets/6cafcaf3-67ce-4175-b026-2f6f29c4818e" />
    
    📊 Benchmarks & Performance

This engine pushes Delphi and the Windows OS to their absolute limits. By offloading logic to a background thread and asynchronously queuing render commands, we achieve staggering framerates:
     
Hardware  --- Max Stable FPS tested here:     
	    
Ryzen 7 5800X + RTX 2060 Super	-   2500 FPS	Maximum Windows Message Queue throughput reached.    
Ryzen 5 4500U (Vega iGPU)	      -   2000 FPS	Incredible performance for an integrated GPU.    
Intel Core m3 (Asus UX305CA)	  -   1000 FPS	Achieved on a passive, fanless ultrabook! Yes he ot started burning or exploded still oO      
      
⚠️ The "Limit" (Why it breaks at 2500 FPS)    
   
You might wonder: "Why does the trackbar freeze above 2500 FPS?" 

This is not an engine bottleneck, but the absolute physical limit of the Windows Message Queue combined with the Delphi VCL. 
To render an SDL window created in the main thread, we use TThread.Queue to push render commands from the background thread to the VCL main thread. At 2500+ FPS, we are pushing 2500+ messages per second into the Windows queue. Eventually, the main thread spends 100% of its time executing RenderEffect and cannot process UI inputs (like dragging the window or moving a trackbar). 
      
Interestingly, the SDL animation itself often continues rendering perfectly in the background, even when the VCL UI elements have frozen!    
     
✨ Features & Architecture     
     
     Dynamic SDL3 Binding: No static .obj or .dcu files required. The SDL3.dll is loaded dynamically via LoadLibrary. If the DLL is missing, the component fails gracefully.
     Asynchronous Multi-Threading: The heavy math, physics, and frame-timing calculations run in a background worker thread. Only the final render command is pushed to the main thread, ensuring 0% blockage on your logic thread.
     Hybrid High-Resolution Timer: Utilizes TStopwatch (QPC) for microsecond accuracy. It uses Sleep(1) for the bulk of the wait time, and a tight 2ms spinlock at the end to guarantee frame-perfect timing without context switching overhead.
     FPU Exception Masking: Delphi's default FPU settings catch exceptions (like precision loss or denormals) that C-libraries like SDL generate constantly. This component explicitly masks the FPU control word (Set8087CW($133F)) at thread start, preventing massive slowdowns and random crashes.

🛠️ Getting Started
Requirements

     Delphi (VCL supported, tested with modern Delphi versions)
     SDL3.dll placed in the same directory as your compiled .exe (you can get it from the official SDL3 GitHub releases).
     
Sample exe and project included    
    
Customizing the Renderer     
    
To draw your own 3D scenes, simply inherit from TSDL3CustomThreadedBase and override the following methods:    
    
     UpdateLogic(DeltaTime): Write your physics and movement code here. Runs in the background thread.
     RenderEffect(ATime): Write your SDL rendering code here. Runs asynchronously in the main thread.
     InitSDLResources / ShutdownSDLResources: Load and free your custom SDL textures or geometries.
   
📝 License    
    
This project is open-source. Feel free to use, modify, and distribute it in your own Delphi applications. 
