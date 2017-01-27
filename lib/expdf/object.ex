defmodule Expdf.Object do
  alias Expdf.Header

  defstruct [:content, :header]

  def new(parser, header, content) do
    case Header.get(parser, header, "Type") do
      {:error, reason} -> {:error, reason}
      {:ok, header, obj} -> case Expdf.Element.content(obj) do
        #"XObject" ->
        _ -> %__MODULE__{content: content, header: header}
      end
    end

        #switch ($header->get('Type')->getContent()) {
            #case 'XObject':
                #switch ($header->get('Subtype')->getContent()) {
                    #case 'Image':
                        #return new Image($document, $header, $content);

                    #case 'Form':
                        #return new Form($document, $header, $content);

                    #default:
                        #return new Object($document, $header, $content);
                #}
                #break;

            #case 'Pages':
                #return new Pages($document, $header, $content);

            #case 'Page':
                #return new Page($document, $header, $content);

            #case 'Encoding':
                #return new Encoding($document, $header, $content);

            #case 'Font':
                #$subtype   = $header->get('Subtype')->getContent();
                #$classname = '\Smalot\PdfParser\Font\Font' . $subtype;

                #if (class_exists($classname)) {
                    #return new $classname($document, $header, $content);
                #} else {
                    #return new Font($document, $header, $content);
                #}

            #default:
                #return new Object($document, $header, $content);
        #}
  end
end
