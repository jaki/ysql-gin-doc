MAIN = gin.tex
TC = xelatex

gin.pdf: $(MAIN) common.sty src/*
	$(TC) -shell-escape $(MAIN)
