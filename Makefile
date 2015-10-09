run: all

all:
	./knit.R tutorial-p4.Rmd
	# osascript -e 'tell application "Google Chrome" to activate'
	osascript -e 'tell application "Google Chrome" to reload active tab of window 1'
	./knit.R tutorial-p1.Rmd
	./knit.R tutorial-p2.Rmd
	./knit.R tutorial-p3.Rmd
	
