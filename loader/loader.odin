package loader
// generic autoreloading program loader

import "core:dynlib"
import "core:fmt"
import "core:os"
import rt "core:runtime"
import "core:strings"
import "core:sys/linux"
import "core:time"

import "siopkgs:alloc"

Continue :: struct {}
Stop_Execution :: struct {
    return_code: i32,
}
Reload :: struct {
    soname: string,
}

Loader_Action :: union #no_nil { Reload, Stop_Execution, Continue }

// it is expected this will be fetched using a procedure named "get_loader_procs" that is properly exported by the shared object
Procs :: struct {
    query_data_type: proc "contextless" () -> rt.Type_Info,
    init: proc "contextless" (start: rawptr, size: u64, arg: rawptr),
    destroy: proc "contextless" (),
    
    // NOT called on init
    setup_after_reload: proc "contextless" (start: rawptr, size: u64, arg: rawptr),
    main_loop_step: proc "contextless" (delta: f64) -> Loader_Action,
}

Loader_Data :: struct {
    lib: dynlib.Library,
    procs: Procs,
    get_procs: proc "contextless" () -> Procs,
    game_data: rawptr,
    game_data_size: u64,
    arg: rawptr,
}

loader_main :: proc(so_name: string, arg: rawptr) -> (return_code: i32 = 0) {
    tick := time.tick_now();
    
    time.sleep(time.Microsecond * 16000); // wait ~16msec
    
    data: Loader_Data;
    data.arg = arg;
    
    if !load_so(&data, so_name) {
        return;
    }
    
    main_loop: for {
        delta := time.duration_seconds(time.tick_lap_time(&tick));
        action := data.procs.main_loop_step(delta);
        switch v in action {
            case Continue: { /* do nothing */ }
            case Stop_Execution: {
                return_code = v.return_code;
                break main_loop;
            }
            
            case Reload: {
                save_point := rt.default_temp_allocator_temp_begin();
                soname := strings.clone(v.soname, allocator = context.temp_allocator);
                reload_so(&data, soname);
                rt.default_temp_allocator_temp_end(save_point);
            }   
        }
    }
    
    data.procs.destroy();
    
    return;
}

bare_load_game_so :: proc(
    so_name: string
    ) -> (lib: dynlib.Library, get_procs_f: proc "contextless" () -> Procs, success: bool)
{
    when
#defined(dynlib.last_error)
    {
        lib, success = dynlib.load_library(so_name);
        if !success {
            fmt.eprintln("Failed to load shared object", so_name, "; error:", dynlib.last_error());
            return;
        }
    } else {
        flags := os.RTLD_NOW;
        os_lib := os.dlopen(so_name, flags);
        if os_lib == nil {
            success = false;
            fmt.eprintln("Failed to load shared object", so_name, "; error:", os.dlerror());
            return;
        }
        lib = dynlib.Library(os_lib);
    }
    
    get_procs_raw: rawptr;
    get_procs_raw, success = dynlib.symbol_address(lib, "get_loader_procs");
    if !success {
        fmt.eprintln("Failed to get procedure get_loader_procs from shared object", so_name);
        return;
    }
    
    get_procs_f = transmute(proc "contextless" () -> Procs) get_procs_raw;
    
    success = true;
    return;
}

get_procs :: proc(
    get_procs_f: proc "contextless" () -> Procs
    ) -> (procs: Procs, success: bool)
{
    procs = get_procs_f();
    if procs.query_data_type == nil || procs.init == nil || procs.destroy == nil || procs.setup_after_reload == nil || procs.main_loop_step == nil {
        fmt.eprintln("Failed to find a required function definition in returned procedures struct");
        fmt.eprintln("None of the following fields may be nil. One of them is. Please fill them in with a do-nothing stub function at minimum.");
        fmt.eprintln(procs);
        success = false;
    } else {
        success = true;
    }
    return;
}

load_so :: proc(data: ^Loader_Data, so_name: string) -> (success: bool) {
    data.lib, data.get_procs, success = bare_load_game_so(so_name);
    if !success {
        fmt.eprintln("Failed to load game so at", so_name);
        return;
    }
    
    data.procs, success = get_procs(data.get_procs);
    
    if !success {
        return;
    }
    
    {
        using data;
        using data.procs;
        
        ti := query_data_type();
        if ti.size <= 0 {
            fmt.eprintln("query_data_type() returned a type with size <= 0. Can't allocate game data.");
            success = false;
            return;
        }
        
        game_data_size = u64(ti.size);
        
        err: linux.Errno;
        game_data, err = alloc.virtual_map(game_data_size);
        if err != .NONE {
            fmt.eprintln("Failed to allocate", game_data_size, "bytes for game data; got error", err);
            success = false;
            return;
        }
        
        init(game_data, game_data_size, arg);
    }
    success = true;
    return;
}

reload_so :: proc(data: ^Loader_Data, so_name: string) -> (success: bool) {
    new_lib: dynlib.Library;
    new_get_procs: proc "contextless" () -> Procs;
    new_lib, new_get_procs, success = bare_load_game_so(so_name);
    if !success {
        fmt.eprintln("Failed to load game so at", so_name, "; not reloading.");
        return;
    }
    
    new_procs: Procs;
    new_procs, success = get_procs(new_get_procs);
    if !success {
        fmt.eprintln("Failed to get procs from game so at", so_name, "; not reloading.");
        return;
    }
    
    dynlib.unload_library(data.lib);
    
    data.lib = new_lib;
    data.get_procs = new_get_procs;
    data.procs = new_procs;
    
    data.procs.setup_after_reload(data.game_data, data.game_data_size, data.arg);
    
    success = true;
    return;
}
