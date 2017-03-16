defmodule Expdf.Document do
  defstruct [:trailer, :dictionary, :details]

  alias Expdf.Header
  alias Expdf.Parser

  def get_pages(%__MODULE__{dictionary: dictionary} = document) do
    IO.inspect(dictionary)
          #if (isset($this->dictionary['Catalog'])) {
            #// Search for catalog to list pages.
            #$id = reset($this->dictionary['Catalog']);

            #/** @var Pages $object */
            #$object = $this->objects[$id]->get('Pages');
            #if (method_exists($object, 'getPages')) {
                #$pages = $object->getPages(true);
                #return $pages;
            #}
        #}

        #if (isset($this->dictionary['Pages'])) {
            #// Search for pages to list kids.
            #$pages = array();

            #/** @var Pages[] $objects */
            #$objects = $this->getObjectsByType('Pages');
            #foreach ($objects as $object) {
                #$pages = array_merge($pages, $object->getPages(true));
            #}

            #return $pages;
        #}

        #if (isset($this->dictionary['Page'])) {
            #// Search for 'page' (unordered pages).
            #$pages = $this->getObjectsByType('Page');

            #return array_values($pages);
        #}

        #throw new \Exception('Missing catalog.');

  end

  def parse_details(%Parser{} = parser, %__MODULE__{trailer: trailer} = document) do
    details = case Header.get(parser, trailer, "Info") do
      {:ok, _, nil} -> %{}
      {:ok, header, obj} ->
        {_, header, _} = obj
        Header.get_details(header)
    end

    document = %{document | details: details}
    pages = case get_pages(document) do
      {:ok, pages} -> Enum.count(pages)
      {:error, _reason} -> 0
    end

    %{document | details: Map.put(details, :"Pages", pages)}
  end
end
