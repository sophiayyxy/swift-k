type messagefile;

(messagefile a, messagefile b) greeting(string m) { 
    app {
        echo m stdout=@filename(a) stderr=@filename(b);
    }
}

messagefile firstfile <"121-multi-return-vars.first.out">;
messagefile secondfile <"121-multi-return-vars.second.out">;

(firstfile, secondfile) = greeting("hi");

