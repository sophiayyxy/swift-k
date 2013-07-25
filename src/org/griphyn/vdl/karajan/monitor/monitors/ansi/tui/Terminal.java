/*
 * Copyright 2012 University of Chicago
 * 
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 * http://www.apache.org/licenses/LICENSE-2.0
 * 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */


package org.griphyn.vdl.karajan.monitor.monitors.ansi.tui;

import java.io.IOException;
import java.util.LinkedList;
import java.util.ListIterator;

public class Terminal extends Component {
    public static final int SCROLLBACK_BUFFER_SIZE = 512;
    
    private LinkedList<String> lines;
    private String prompt;
    private StringBuffer input;
    private InputHandler inputHandler;
    private int end = -1;

    public Terminal() {
        lines = new LinkedList<String>();
        bgColor = ANSI.BLACK;
        fgColor = ANSI.WHITE;
        prompt = "> ";
        input = new StringBuffer();
    }

    protected void draw(ANSIContext context) throws IOException {
        synchronized (lines) {
            context.bgColor(bgColor);
            context.filledRect(sx, sy, width, height);
            context.fgColor(fgColor);
            
            int crt = Math.min(height - 2, lines.size()) + 1;
            if (end < 0) {
                context.moveTo(sx, sy + crt);
                context.text(prompt);
                context.text(input.toString());
                context.bgColor(fgColor);
                context.putChar(' ');
                context.bgColor(bgColor);
                context.fgColor(fgColor);
                crt--;
            }
            else {
                System.out.println();
            }
            ListIterator<String> li = lines.listIterator(lines.size());
            int skip = end;
            while (li.hasPrevious() && skip > 0) {
                li.previous();
                skip--;
            }
            while (li.hasPrevious() && crt >= 0) {
                String line = li.previous();
                context.moveTo(sx, sy + crt);
                context.text(line);
                crt--;
            }
        }
    }

    public String getPrompt() {
        return prompt;
    }

    public void setPrompt(String prompt) {
        this.prompt = prompt;
    }

    public boolean keyboardEvent(Key key) {
        if (key.isEnter()) {
            end = -1;
            processInput();
        }
        else if (key.equals(Key.BACKSPACE)) {
            end = -1;
            input.deleteCharAt(input.length() - 1);
        }
        else if (key.equals(Key.TAB)) {
            end = -1;
            if (inputHandler != null) {
                int si = input.lastIndexOf(" ");
                String ac = inputHandler.autoComplete(input.substring(si + 1));
                if (ac != null) {
                    input.delete(si + 1, input.length());
                    input.append(ac);
                }
                redraw();
            }
        }
        else if (key.equals(Key.HOME)) {
            end = lines.size() - height;
        }
        else if (key.equals(Key.END)) {
            end = -1;
        }
        else if (key.equals(Key.PGUP)) {
            end = Math.min(lines.size() - height, end + height);
        }
        else if (key.equals(Key.PGDN)) {
            end -= height;
        }
        else {
            end = -1;
            input.append(key.getChar());
        }
        return true;
    }

    private void processInput() {
        String in = input.toString().trim();
        append(prompt + in);
        input = new StringBuffer();
        if (inputHandler != null) {
            inputHandler.handleInput(in);
        }
        else {
            append("Invalid command: " + in);
        }
    }

    public void append(String str) {
        synchronized (lines) {
            str = str.replaceAll("\\t", "    ");
            String[] l = str.split("\\n");
            for (int i = 0; i < l.length; i++) {
                while (l[i].length() > width) {
                    lines.add(l[i].substring(0, width));
                    l[i] = l[i].substring(width);
                }
                lines.add(l[i]);
            }
            while (lines.size() > SCROLLBACK_BUFFER_SIZE) {
                lines.removeFirst();
            }
            redraw();
        }
    }

    public InputHandler getInputHandler() {
        return inputHandler;
    }

    public void setInputHandler(InputHandler inputHandler) {
        this.inputHandler = inputHandler;
    }

    public static interface InputHandler {
        void handleInput(String in);

        String autoComplete(String in);
    }

}
