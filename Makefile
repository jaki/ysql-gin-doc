NAME = gin
TC = xelatex

.PHONY: clean

default: gin.pdf

clean:
	rm -f $(NAME).{aux,log,out,pdf,toc}
	rm -rf _minted-$(NAME)/

gin.pdf: $(NAME).tex common.sty src/* $(wildcard options.tex)
	$(TC) -shell-escape $(NAME).tex
