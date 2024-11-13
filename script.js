// Función para enviar un nuevo producto al servidor
async function addProduct() {
  const productName = document.getElementById("productName").value;
  const storeName = document.getElementById("storeName").value;
  const productPhoto = document.getElementById("productPhoto").files[0];

  if (productName && storeName && productPhoto && navigator.geolocation) {
    navigator.geolocation.getCurrentPosition(async (position) => {
      const formData = new FormData();
      formData.append("nombre", productName);
      formData.append("tienda", storeName);
      formData.append("foto", productPhoto);
      formData.append("ubicacion[lat]", position.coords.latitude);
      formData.append("ubicacion[lng]", position.coords.longitude);

      // Enviar el producto al backend
      try {
        const response = await fetch("http://localhost:3000/api/productos", {
          method: "POST",
          body: formData,
        });
        const data = await response.json();
        console.log(data.message);
        obtenerProductos();
      } catch (error) {
        console.error("Error al subir el producto:", error);
      }
    });
  } else {
    alert("Por favor, llena todos los campos y permite la geolocalización.");
  }
}

// Función para obtener productos del servidor y mostrarlos en el mapa
async function obtenerProductos() {
  try {
    const response = await fetch("http://localhost:3000/api/productos");
    const productos = await response.json();
    mostrarProductosEnMapa(productos);
  } catch (error) {
    console.error("Error al obtener productos:", error);
  }
}

// Modificar la función para mostrar productos en el mapa
function mostrarProductosEnMapa(productos) {
  productos.forEach((producto) => {
    const marker = new google.maps.Marker({
      position: producto.ubicacion,
      map: map,
      title: `${producto.nombre} - ${producto.tienda}`,
    });

    const infoWindow = new google.maps.InfoWindow({
      content: `
        <h3>${producto.nombre}</h3>
        <p><strong>Tienda:</strong> ${producto.tienda}</p>
        <img src="data:image/png;base64,${producto.foto.toString("base64")}" alt="${producto.nombre}" width="100" />
      `,
    });

    marker.addListener("click", () => {
      infoWindow.open(map, marker);
    });
  });
}

// Llama a obtenerProductos cuando se carga la app
window.onload = () => {
  initMap();
  obtenerProductos();
};
