
type file {} 

(file t) echo (string s) {   
    app {
        echo s stdout=@filename(t);
    }
}

file inputFiles[] <filesys_mapper;pattern="*">;

file o <"foo.out">;
o = echo(@filenames(inputFiles));
