type file {}


(file t) echo_wildcard (string s[]) {
    app {
        echo s[*] stdout=@filename(t);
    }
}

string greetings[] = ["how","are","you"];
file hw = echo(greetings);	

