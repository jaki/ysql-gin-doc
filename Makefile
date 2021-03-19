MAIN = gin.tex
TC = xelatex

gin.pdf: $(MAIN) src/*
	$(TC) -shell-escape $(MAIN)
