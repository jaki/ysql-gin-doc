NAME = gin
TC = xelatex

gin.pdf: $(NAME).tex common.sty src/*
	$(TC) -shell-escape $(NAME).tex
